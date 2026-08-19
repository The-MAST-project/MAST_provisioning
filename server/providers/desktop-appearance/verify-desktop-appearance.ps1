#requires -Version 5.1
# Is the operator desktop appearance CURRENT, not merely present.
#
# Presence proves nothing here. A background rendered before a rename still
# exists, still loads, and still names the wrong host -- which is the whole reason
# an operator would look at it. So the checks compare the sidecar's recorded
# static fields against the live machine, and the deployed registry values against
# what this build would write (docs/per-module-tracking-plan.md, resolution rule 2).
#
# Reads mast's hive through the same mast-userhive-lib.ps1 the provider writes
# through, so the check cannot be looking at a different user than the one
# configured.
[CmdletBinding()]
param(
    [string]${AppearanceRoot} = 'C:\ProgramData\MAST\desktop',
    [string]${UnitToml} = 'C:\WIS\config.toml',
    [string]${MastUser} = 'mast'
)

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
foreach (${libName} in @('mast-userhive-lib.ps1', 'mast-appearance-lib.ps1')) {
    ${libPath} = Join-Path ${PSScriptRoot} ${libName}
    if (-not (Test-Path ${libPath})) { throw ("{0} not found next to verify-desktop-appearance.ps1" -f ${libName}) }
    . ${libPath}
}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts probe optional state
${verifyLog} = Get-MastVerifyLog -Module 'desktop-appearance'

${TaskName}        = 'MAST-DesktopAppearance-Apply'
${ThemeKey}        = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
${DesktopKey}      = 'Control Panel\Desktop'
${WallpaperFill}   = '10'
${TileWallpaperNo} = '0'

function W { param([string]${Line}) Add-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), ${Line}) }
Set-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] verify-desktop-appearance.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

${fail} = @()
${imagePath}   = Join-Path ${AppearanceRoot} 'background.png'
${sidecarPath} = Join-Path ${AppearanceRoot} 'background.json'

# --- the image and what it was rendered from --------------------------------
${sidecar} = $null
if (-not (Test-Path -LiteralPath ${sidecarPath})) {
    ${fail} += ("background sidecar missing: {0}" -f ${sidecarPath})
} else {
    ${sidecar} = Get-Content -LiteralPath ${sidecarPath} -Raw | ConvertFrom-Json
    W ("sidecar present: renderer_version={0} rendered_at={1}" -f ${sidecar}.renderer_version, ${sidecar}.rendered_at)

    if (-not (Test-Path -LiteralPath ${imagePath})) {
        ${fail} += ("background image missing: {0}" -f ${imagePath})
    } elseif ((Get-Item -LiteralPath ${imagePath}).Length -le 0) {
        ${fail} += ("background image is empty: {0}" -f ${imagePath})
    } else {
        W ("background image present: {0} ({1} bytes)" -f ${imagePath}, (Get-Item -LiteralPath ${imagePath}).Length)
    }

    # The staleness check. The expected set comes from the same
    # Get-MastAppearanceFields the provider rendered from, so this compares the
    # image against the machine rather than against a second copy of the
    # formatting. Only static_fields are compared: a field listed in
    # dynamic_fields is live by design and would differ on every read.
    ${expected} = Get-MastAppearanceFields -UnitToml ${UnitToml}
    ${dynamic} = @()
    if (${sidecar}.dynamic_fields) { ${dynamic} = @(${sidecar}.dynamic_fields) }
    foreach (${field} in ${expected}.Keys) {
        if (${dynamic} -contains ${field}) { W ("{0} is declared dynamic; not compared." -f ${field}); continue }
        ${recorded} = ${sidecar}.static_fields.${field}
        if ("${recorded}" -ne "$(${expected}[${field}])") {
            ${fail} += ("background STALE: {0} rendered as '{1}', machine reports '{2}'" -f ${field}, ${recorded}, ${expected}[${field}])
        } else {
            W ("{0} current: {1}" -f ${field}, ${recorded})
        }
    }
}

# --- the per-user values, read out of mast's own hive -----------------------
${hive} = $null
try {
    ${hive} = Resolve-MastUserHive -UserName ${MastUser}
} catch {
    ${fail} += ("could not reach the '{0}' hive: {1}" -f ${MastUser}, $_.Exception.Message)
}
if (${hive}) {
    W ("resolved the '{0}' hive ({1})." -f ${MastUser}, ${hive}.Source)
    foreach (${check} in @(
            @{ SubKey = ${ThemeKey};   Name = 'AppsUseLightTheme';    Expected = 0 },
            @{ SubKey = ${ThemeKey};   Name = 'SystemUsesLightTheme'; Expected = 0 },
            @{ SubKey = ${DesktopKey}; Name = 'Wallpaper';            Expected = ${imagePath} },
            @{ SubKey = ${DesktopKey}; Name = 'WallpaperStyle';       Expected = ${WallpaperFill} },
            @{ SubKey = ${DesktopKey}; Name = 'TileWallpaper';        Expected = ${TileWallpaperNo} })) {
        ${actual} = Get-MastUserHiveValue -Hive ${hive} -SubKey ${check}.SubKey -Name ${check}.Name
        if ($null -eq ${actual}) {
            ${fail} += ("{0} not set in the {1} hive" -f ${check}.Name, ${MastUser})
        } elseif ("${actual}" -ne "$(${check}.Expected)") {
            ${fail} += ("{0} is '{1}', build expects '{2}'" -f ${check}.Name, ${actual}, ${check}.Expected)
        } else {
            W ("{0} current: {1}" -f ${check}.Name, ${actual})
        }
    }
    Close-MastUserHive -Hive ${hive}
} elseif (${fail}.Count -eq 0) {
    # No profile at all: the provider legitimately deferred to the logon task, so
    # there is nothing to read back yet. Say so rather than passing silently.
    W ("[WARN] '{0}' has no profile yet; per-user values not verifiable on this machine." -f ${MastUser})
}

# --- the task that re-asserts it every logon -------------------------------
# Presence is not enough: the task is what makes the appearance visible, and a
# registered task that fails every logon leaves the desktop untouched while every
# other check here passes. Its last exit code is the only trace it leaves -- which
# is how a duplicate `using` directive in the apply script's Add-Type went unnoticed
# on the dev VM until someone read LastTaskResult by hand (2026-08-19).
${TaskNeverRan} = 267011  # 0x41303, SCHED_S_TASK_HAS_NOT_RUN
if (Get-ScheduledTask -TaskName ${TaskName} -ErrorAction SilentlyContinue) {
    W ("AtLogon task present: {0}" -f ${TaskName})
    ${info} = Get-ScheduledTaskInfo -TaskName ${TaskName} -ErrorAction SilentlyContinue
    if (-not ${info}) {
        W '[WARN] task registered but its run info is unreadable; last result not checked.'
    } elseif (${info}.LastTaskResult -eq ${TaskNeverRan}) {
        W 'task has not run yet (no logon since it was registered); nothing to judge.'
    } elseif (${info}.LastTaskResult -ne 0) {
        ${fail} += ("AtLogon task last FAILED: result {0} at {1} -- the desktop is not being repainted (see {2}\apply.log)" -f ${info}.LastTaskResult, ${info}.LastRunTime, ${AppearanceRoot})
    } else {
        W ("task last ran clean at {0}" -f ${info}.LastRunTime)
    }
} else {
    ${fail} += ("AtLogon task missing: {0}" -f ${TaskName})
}

if (${fail}.Count -eq 0) {
    W 'PASS desktop appearance current'
    Write-MastSmokeOk -Module 'desktop-appearance' | Out-Null
    exit 0
}
W ('FAIL ' + (${fail} -join '; '))
exit 1
