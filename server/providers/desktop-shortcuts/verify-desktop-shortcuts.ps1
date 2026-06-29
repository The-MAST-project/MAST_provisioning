#requires -Version 5.1
[CmdletBinding()]
param(
    [string]${Ds9Exe} = 'C:\Program Files\SAOImageDS9\ds9.exe'
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
${desktop} = Join-Path ${env:PUBLIC} 'Desktop'

# FastAPI control shortcut (always created).
${fastApiPath} = Join-Path ${desktop} 'MAST Unit (FastAPI).url'
if (Test-Path -LiteralPath ${fastApiPath}) { W ("FastAPI shortcut present: {0}" -f ${fastApiPath}) }
else { ${fail} += ("FastAPI shortcut missing ({0})" -f ${fastApiPath}) }

# Logs folder shortcut (always created).
${logsPath} = Join-Path ${desktop} 'MAST Logs.lnk'
if (Test-Path -LiteralPath ${logsPath}) { W ("Logs shortcut present: {0}" -f ${logsPath}) }
else { ${fail} += ("Logs shortcut missing ({0})" -f ${logsPath}) }

# DS9 shortcut: required only when DS9 itself is installed (ds9 provider runs
# first in a full cycle; absent in an isolated desktop-shortcuts run).
${ds9Path} = Join-Path ${desktop} 'SAOImage DS9.lnk'
if (Test-Path -LiteralPath ${Ds9Exe}) {
    if (Test-Path -LiteralPath ${ds9Path}) { W ("DS9 shortcut present: {0}" -f ${ds9Path}) }
    else { ${fail} += ("DS9 shortcut missing though ds9.exe present ({0})" -f ${ds9Path}) }
} else {
    W 'DS9 exe absent; DS9 shortcut not required.'
}

# Weather shortcut: created from the provider default / -WeatherUrl. Presence depends on
# site config, so this is informational -- logged, never failed -- and matched by glob so
# verify need not duplicate the URL or the site label.
${weatherHits} = @(Get-ChildItem -LiteralPath ${desktop} -Filter '*Weather (Meteoblue).url' -File -ErrorAction SilentlyContinue)
if (${weatherHits}.Count -gt 0) { W ("Weather shortcut present: {0}" -f ${weatherHits}[0].Name) }
else { W 'No weather shortcut on desktop (URL not configured?).' }

if (${fail}.Count -eq 0) {
    W 'PASS desktop shortcuts present'
    Write-MastSmokeOk -Module 'desktop-shortcuts' | Out-Null
    exit 0
}
W ('FAIL ' + (${fail} -join '; '))
exit 1
