#requires -Version 5.1
[CmdletBinding()]
param(
    [string]${Ds9Exe} = 'C:\Program Files\SAOImageDS9\ds9.exe',
    # The URL the CURRENT build would deploy. Injected from module.json's verify
    # command, the same place the provider's -FastApiUrl comes from, so the two
    # cannot drift apart. This is what makes the check answer "is the shortcut
    # CURRENT?" rather than merely "does the shortcut exist?" -- see
    # docs/per-module-tracking-plan.md, resolution rule 2.
    [string]${FastApiUrl} = ''
)

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts probe optional state
${verifyLog} = Get-MastVerifyLog -Module 'desktop-shortcuts'

function W { param([string]${Line}) Add-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), ${Line}) }
Set-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] verify-desktop-shortcuts.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

${fail} = @()
${desktop}  = Join-Path ${env:PUBLIC} 'Desktop'
${mastRoot} = Join-Path ${desktop} 'MAST'
${dirOps}   = Join-Path ${mastRoot} 'Operations'
${dirSetup} = Join-Path ${mastRoot} 'Setup and Calibration'
${dirDev}   = Join-Path ${mastRoot} 'Development'
${dirVendor}= Join-Path ${mastRoot} 'Vendor'

# Folder structure + per-folder READMEs.
foreach (${d} in @(${mastRoot}, ${dirOps}, ${dirSetup}, ${dirDev}, ${dirVendor})) {
    if (-not (Test-Path -LiteralPath ${d})) { ${fail} += ("folder missing: {0}" -f ${d}); continue }
    if (-not (Test-Path -LiteralPath (Join-Path ${d} 'README.txt'))) { ${fail} += ("README missing in {0}" -f ${d}) }
}

# Required shortcuts in their class folders.
${required} = @(
    (Join-Path ${dirOps}   'MAST Unit (FastAPI).url'),
    (Join-Path ${dirOps}   'MAST Logs.lnk'),
    (Join-Path ${dirOps}   'MAST Proxy.lnk'),
    (Join-Path ${dirSetup} 'MAST Instrument Calibration.lnk'),
    (Join-Path ${dirSetup} 'MAST Installation Directory.lnk')
)
foreach (${r} in ${required}) {
    if (Test-Path -LiteralPath ${r}) { W ("present: {0}" -f ${r}) }
    else { ${fail} += ("shortcut missing ({0})" -f ${r}) }
}

# Content check, not presence check: a shortcut left pointing at a previous
# build's URL passes every Test-Path in this file. Repointing the FastAPI
# shortcut changes no commandfile byte -- the target lives in module.json's
# command args -- so a stale target is invisible to both the payload hash and a
# presence-only verify. Compare the deployed target to what this build expects.
${fastApiLnk} = Join-Path ${dirOps} 'MAST Unit (FastAPI).url'
if (${FastApiUrl} -and (Test-Path -LiteralPath ${fastApiLnk})) {
    ${urlLine} = @(Get-Content -LiteralPath ${fastApiLnk} -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '^\s*URL\s*=' }) | Select-Object -First 1
    ${deployed} = ''
    if (${urlLine}) { ${deployed} = (${urlLine} -replace '^\s*URL\s*=', '').Trim() }
    if (-not ${deployed}) {
        ${fail} += ("FastAPI shortcut has no URL= line ({0})" -f ${fastApiLnk})
    }
    elseif (${deployed}.TrimEnd('/') -ne ${FastApiUrl}.TrimEnd('/')) {
        ${fail} += ("FastAPI shortcut STALE: points at '{0}', build expects '{1}'" -f ${deployed}, ${FastApiUrl})
    }
    else {
        W ("FastAPI shortcut target current: {0}" -f ${deployed})
    }
}

# DS9 shortcut: required only when DS9 itself is installed (ds9 provider runs
# first in a full cycle; absent in an isolated desktop-shortcuts run).
${ds9Path} = Join-Path ${dirOps} 'SAOImage DS9.lnk'
if (Test-Path -LiteralPath ${Ds9Exe}) {
    if (Test-Path -LiteralPath ${ds9Path}) { W ("DS9 shortcut present: {0}" -f ${ds9Path}) }
    else { ${fail} += ("DS9 shortcut missing though ds9.exe present ({0})" -f ${ds9Path}) }
} else {
    W 'DS9 exe absent; DS9 shortcut not required.'
}

# Weather shortcut: informational -- presence depends on site config.
${weatherHits} = @(Get-ChildItem -LiteralPath ${dirOps} -Filter '*Weather (Meteoblue).url' -File -ErrorAction SilentlyContinue)
if (${weatherHits}.Count -gt 0) { W ("Weather shortcut present: {0}" -f ${weatherHits}[0].Name) }
else { W 'No weather shortcut (URL not configured?).' }

# The QoL contract: NOTHING loose on the desktop roots -- everything lives
# under Desktop\MAST. (The provider sweeps strays into MAST\Vendor.)
${sweepRoots} = @(${desktop})
if (Test-Path -LiteralPath 'C:\Users\mast\Desktop') { ${sweepRoots} += 'C:\Users\mast\Desktop' }
foreach (${root} in ${sweepRoots}) {
    ${loose} = @(Get-ChildItem -LiteralPath ${root} -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.lnk', '.url') })
    if (${loose}.Count -gt 0) {
        ${fail} += ("loose shortcuts on {0}: {1}" -f ${root}, ((${loose} | ForEach-Object { $_.Name }) -join ', '))
    } else {
        W ("desktop root clean: {0}" -f ${root})
    }
}

if (${fail}.Count -eq 0) {
    W 'PASS desktop shortcuts organized under MAST\'
    Write-MastSmokeOk -Module 'desktop-shortcuts' | Out-Null
    exit 0
}
W ('FAIL ' + (${fail} -join '; '))
exit 1
