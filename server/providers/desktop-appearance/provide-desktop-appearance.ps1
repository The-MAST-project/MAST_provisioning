# Phase 1: the unit's operator desktop appearance -- dark Windows theme and a dark
# background carrying the machine's identity (MAST_provisioning#54).
#
# Both are per-user settings on a machine whose desktop belongs to the autologin
# 'mast' account, while provisioning runs over WinRM as somebody else. So this
# script does three separable things:
#
#   1. Renders the background machine-wide into ${AppearanceRoot}, from the fields
#      Get-MastAppearanceFields derives: the hostname, the site (spelled out from
#      the code in the deployed C:\WIS\config.toml -- the single source of truth
#      config-bootstrap writes, never the hostname) and the site coordinates.
#      Machine-scope, so it is verifiable without a user session.
#   2. Writes the theme and wallpaper values into mast's hive directly, via
#      mast-userhive-lib.ps1. On a provisioned unit mast is signed in and the hive
#      is already mounted at HKU\<sid>, so this is a plain write; with nobody
#      signed in the lib loads NTUSER.DAT instead. It never falls back to HKCU
#      (see MAST_provisioning#106 for what that costs).
#   3. Removes the retired MAST-DesktopAppearance-Apply task if this unit still
#      carries one. Repainting the live desktop moved into
#      client/execute-mast-provisioning.ps1, which runs as mast inside the logon
#      session AND elevated -- the combination the task never had, and the reason
#      it could not re-render a machine-wide image (#206).
#
# Order 2750: after desktop-shortcuts (2700) so the operator-desktop modules sit
# together, and long after config-bootstrap (150) whose config.toml step 1 reads.

[CmdletBinding()]
param(
    [string]${AppearanceRoot} = 'C:\ProgramData\MAST\desktop',
    # Bootstrap config the site and role are read from (deployed by config-bootstrap).
    [string]${UnitToml} = 'C:\WIS\config.toml',
    [string]${MastUser} = 'mast'
)

${ErrorActionPreference} = 'Stop'

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
foreach (${libName} in @('mast-userhive-lib.ps1', 'mast-appearance-lib.ps1')) {
    ${libPath} = Join-Path ${PSScriptRoot} ${libName}
    if (-not (Test-Path ${libPath})) { throw ("{0} not found next to provide-desktop-appearance.ps1" -f ${libName}) }
    . ${libPath}
}

${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} 'desktop-appearance.log'

${RetiredTaskName} = 'MAST-DesktopAppearance-Apply'

function Write-AppearanceLog {
    param([string]${Line})
    ${stamp} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${stamp}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-desktop-appearance.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    New-Item -ItemType Directory -Path ${AppearanceRoot} -Force | Out-Null

    # 1) What the background states. Derived through the shared lib so verify can
    #    recompute the identical set and compare. A missing config or manifest
    #    yields empty fields, and the renderer drops those lines rather than
    #    printing a placeholder -- the hostname, the point of the exercise, always
    #    resolves.
    #
    #    Step 4 below writes more than the theme and the wallpaper: the toast and
    #    content-delivery suppressions moved here from bootstrap in #106, so every
    #    per-user value the operator desktop owns is written in one place.
    ${fields} = Get-MastAppearanceFields -UnitToml ${UnitToml}
    if (-not (Test-Path -LiteralPath ${UnitToml})) {
        Write-AppearanceLog ("[WARN] {0} absent (config-bootstrap not run?); site and coordinates omitted from the image." -f ${UnitToml})
    }
    Write-AppearanceLog ("Background states: site={0} ({1}) coords='{2}'" -f ${fields}.site_name, ${fields}.site, ${fields}.coordinates)

    # 2) Stage the renderer and the lib at a persistent path, so a re-render on a
    #    unit needs no payload. execute-mast-provisioning.ps1 dot-sources the lib
    #    from here at the end of every run, long after the staging directory is
    #    gone, for Update-MastStaleBackground and Set-MastLiveDesktop.
    foreach (${name} in @('render-desktop-background.ps1', 'mast-appearance-lib.ps1')) {
        ${src} = Join-Path ${PSScriptRoot} ${name}
        if (-not (Test-Path -LiteralPath ${src})) { throw ("{0} not found for staging" -f ${name}) }
        Copy-Item -LiteralPath ${src} -Destination (Join-Path ${AppearanceRoot} ${name}) -Force
    }
    Write-AppearanceLog ("Staged renderer + appearance lib into {0}" -f ${AppearanceRoot})

    # 3) Render the background and its sidecar.
    ${imagePath}   = Join-Path ${AppearanceRoot} 'background.png'
    ${sidecarPath} = Join-Path ${AppearanceRoot} 'background.json'
    # No exit-code test on the call: $LASTEXITCODE is a native-process concept and a
    # .ps1 invocation does not set it, so such a guard never fires (see
    # server/prov/tests/test_provider_failure_reporting.py). The renderer runs with
    # $ErrorActionPreference = 'Stop', so a failure propagates as a terminating error
    # into this script's catch. What is checked is the OUTCOME -- the two artifacts
    # everything downstream reads.
    & (Join-Path ${AppearanceRoot} 'render-desktop-background.ps1') `
        -OutputPath ${imagePath} -SidecarPath ${sidecarPath} `
        -ComputerName (${fields}.computer_name) -SiteCode (${fields}.site) -SiteName (${fields}.site_name) `
        -Coordinates (${fields}.coordinates) -Provisioned (${fields}.provisioned)
    foreach (${artifact} in @(${imagePath}, ${sidecarPath})) {
        if (-not (Test-Path -LiteralPath ${artifact})) { throw ("render-desktop-background.ps1 produced no {0}" -f ${artifact}) }
    }
    Write-AppearanceLog ("Rendered background for {0} -> {1}" -f ${env:COMPUTERNAME}, ${imagePath})

    # 4) Write the per-user values into mast's hive. A machine where mast has never
    #    signed in has no profile yet: nothing to write, and the first logon reads
    #    the defaults the profile is created with -- the next run writes the hive.
    ${hive} = Resolve-MastUserHive -UserName ${MastUser}
    if (${hive}) {
        ${userValues} = Get-MastDesktopUserValues -WallpaperPath ${imagePath}
        foreach (${value} in ${userValues}) {
            Set-MastUserHiveValue -Hive ${hive} -SubKey ${value}.SubKey -Name ${value}.Name -Value ${value}.Value -Type ${value}.Type
        }
        Close-MastUserHive -Hive ${hive}
        Write-AppearanceLog ("Wrote {0} per-user values into the '{1}' hive ({2})." -f ${userValues}.Count, ${MastUser}, ${hive}.Source)
    } else {
        Write-AppearanceLog ("[WARN] '{0}' has no profile yet; hive write skipped, first logon applies it." -f ${MastUser})
    }

    # 5) Remove the retired apply task. Not registering it is not enough -- every
    #    unit in the field has one, and a task nobody maintains that repaints the
    #    desktop from a stale sidecar is worse than none. This module's own files
    #    changed, so it drifts on every unit and this runs once everywhere.
    if (Get-ScheduledTask -TaskName ${RetiredTaskName} -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName ${RetiredTaskName} -Confirm:$false
        Write-AppearanceLog ("Removed the retired task '{0}'; execute repaints the desktop now." -f ${RetiredTaskName})
    }
    ${retiredApply} = Join-Path ${AppearanceRoot} 'apply-desktop-appearance.ps1'
    if (Test-Path -LiteralPath ${retiredApply}) {
        Remove-Item -LiteralPath ${retiredApply} -Force
        Write-AppearanceLog ("Removed the retired {0}." -f ${retiredApply})
    }

    Write-MastSmokeOk -Module 'desktop-appearance' | Out-Null
    Write-AppearanceLog 'desktop-appearance provisioning complete.'
    exit 0
}
catch {
    Write-AppearanceLog ("FAILED: {0}" -f $_)
    exit 1
}
