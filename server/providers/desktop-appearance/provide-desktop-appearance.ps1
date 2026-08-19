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
#      config-bootstrap writes, never the hostname), the site coordinates, and the
#      provisioning commit the payload carries. Machine-scope, so it is verifiable
#      without a user session.
#   2. Writes the theme and wallpaper values into mast's hive directly, via
#      mast-userhive-lib.ps1. On a provisioned unit mast is signed in and the hive
#      is already mounted at HKU\<sid>, so this is a plain write; with nobody
#      signed in the lib loads NTUSER.DAT instead. It never falls back to HKCU
#      (see MAST_provisioning#106 for what that costs).
#   3. Registers apply-desktop-appearance.ps1 as an AtLogon task for mast, and
#      starts it now when mast is already signed in. That task exists for the two
#      things a registry write cannot do -- repaint the wallpaper and make the
#      shell re-read the theme -- and it stays registered, because appearance is
#      standing state that every logon has to re-assert.
#
# Order 2750: after desktop-shortcuts (2700) so the operator-desktop modules sit
# together, and long after config-bootstrap (150) whose config.toml step 1 reads.

[CmdletBinding()]
param(
    [string]${AppearanceRoot} = 'C:\ProgramData\MAST\desktop',
    # Bootstrap config the site and role are read from (deployed by config-bootstrap).
    [string]${UnitToml} = 'C:\WIS\config.toml',
    [string]${MastUser} = 'mast',
    # Skip the AtLogon task registration (render-and-write-only test runs).
    [switch]${SkipTask}
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

${TaskName}     = 'MAST-DesktopAppearance-Apply'
${ThemeKey}     = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
${DesktopKey}   = 'Control Panel\Desktop'
${WallpaperFill}   = '10'
${TileWallpaperNo} = '0'

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
    #    The build manifest sits in the staging root next to this script (staging is
    #    flattened), and it describes the payload being installed RIGHT NOW --
    #    unlike installed-manifest.json, which at order 2750 still describes the
    #    previous run.
    ${fields} = Get-MastAppearanceFields -UnitToml ${UnitToml} -BuildManifestPath (Join-Path ${PSScriptRoot} 'build-manifest.json')
    if (-not (Test-Path -LiteralPath ${UnitToml})) {
        Write-AppearanceLog ("[WARN] {0} absent (config-bootstrap not run?); site and coordinates omitted from the image." -f ${UnitToml})
    }
    if (-not ${fields}.payload) {
        Write-AppearanceLog '[WARN] no build-manifest.json in the staging root; payload stamp omitted from the image.'
    }
    Write-AppearanceLog ("Background states: site={0} ({1}) coords='{2}' payload={3}" -f ${fields}.site_name, ${fields}.site, ${fields}.coordinates, ${fields}.payload)

    # 2) Stage the renderer and the apply script at a persistent path. The AtLogon
    #    task runs long after the staging dir is gone, and the renderer follows it
    #    so a re-render on a unit needs no payload.
    foreach (${name} in @('render-desktop-background.ps1', 'apply-desktop-appearance.ps1')) {
        ${src} = Join-Path ${PSScriptRoot} ${name}
        if (-not (Test-Path -LiteralPath ${src})) { throw ("{0} not found for staging" -f ${name}) }
        Copy-Item -LiteralPath ${src} -Destination (Join-Path ${AppearanceRoot} ${name}) -Force
    }
    Write-AppearanceLog ("Staged renderer + apply script into {0}" -f ${AppearanceRoot})

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
        -Coordinates (${fields}.coordinates) -Payload (${fields}.payload)
    foreach (${artifact} in @(${imagePath}, ${sidecarPath})) {
        if (-not (Test-Path -LiteralPath ${artifact})) { throw ("render-desktop-background.ps1 produced no {0}" -f ${artifact}) }
    }
    Write-AppearanceLog ("Rendered background for {0} -> {1}" -f ${env:COMPUTERNAME}, ${imagePath})

    # 4) Write the per-user values into mast's hive. A machine where mast has never
    #    signed in has no profile yet: nothing to write, and the AtLogon task is
    #    what covers it.
    ${hive} = Resolve-MastUserHive -UserName ${MastUser}
    if (${hive}) {
        Set-MastUserHiveValue -Hive ${hive} -SubKey ${ThemeKey}   -Name 'AppsUseLightTheme'    -Value 0 -Type DWord
        Set-MastUserHiveValue -Hive ${hive} -SubKey ${ThemeKey}   -Name 'SystemUsesLightTheme' -Value 0 -Type DWord
        Set-MastUserHiveValue -Hive ${hive} -SubKey ${DesktopKey} -Name 'Wallpaper'      -Value ${imagePath}       -Type String
        Set-MastUserHiveValue -Hive ${hive} -SubKey ${DesktopKey} -Name 'WallpaperStyle' -Value ${WallpaperFill}   -Type String
        Set-MastUserHiveValue -Hive ${hive} -SubKey ${DesktopKey} -Name 'TileWallpaper'  -Value ${TileWallpaperNo} -Type String
        Close-MastUserHive -Hive ${hive}
        Write-AppearanceLog ("Wrote theme + wallpaper into the '{0}' hive ({1})." -f ${MastUser}, ${hive}.Source)
    } else {
        Write-AppearanceLog ("[WARN] '{0}' has no profile yet; hive write skipped, first logon applies it." -f ${MastUser})
    }

    # 5) The AtLogon task. Interactive and non-elevated: it has to run inside the
    #    session to repaint the desktop, and needs nothing more.
    if (-not ${SkipTask}) {
        ${applyPath} = Join-Path ${AppearanceRoot} 'apply-desktop-appearance.ps1'
        ${argLine} = ('-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "{0}" -AppearanceRoot "{1}"' -f ${applyPath}, ${AppearanceRoot})
        ${action}    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ${argLine}
        ${trigger}   = New-ScheduledTaskTrigger -AtLogOn -User ${MastUser}
        ${principal} = New-ScheduledTaskPrincipal -UserId ${MastUser} -LogonType Interactive -RunLevel Limited
        ${settings}  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Unregister-ScheduledTask -TaskName ${TaskName} -ErrorAction SilentlyContinue -Confirm:$false
        Register-ScheduledTask -TaskName ${TaskName} `
            -Description 'Apply the MAST dark theme and identity background in the mast logon session (re-asserted every logon).' `
            -Action ${action} -Trigger ${trigger} -Principal ${principal} -Settings ${settings} -ErrorAction Stop | Out-Null
        Write-AppearanceLog ("Registered AtLogon task '{0}' for user '{1}'." -f ${TaskName}, ${MastUser})

        # A mounted hive means the account has an active profile, so the task can
        # run now and the desktop changes without waiting for a sign-in. An
        # Interactive task cannot start with nobody logged on, so a failure here is
        # expected on such a machine and is not the module's problem: the trigger
        # covers it.
        if (${hive} -and ${hive}.Source -eq 'mounted') {
            try {
                Start-ScheduledTask -TaskName ${TaskName} -ErrorAction Stop
                Write-AppearanceLog 'Started the apply task in the live session.'
            } catch {
                Write-AppearanceLog ("[WARN] could not start the apply task now ({0}); it runs at the next logon." -f $_.Exception.Message)
            }
        } else {
            Write-AppearanceLog 'No active mast session; the apply task runs at the next logon.'
        }
    } else {
        Write-AppearanceLog 'SkipTask set; AtLogon task registration skipped.'
    }

    Write-MastSmokeOk -Module 'desktop-appearance' | Out-Null
    Write-AppearanceLog 'desktop-appearance provisioning complete.'
    exit 0
}
catch {
    Write-AppearanceLog ("FAILED: {0}" -f $_)
    exit 1
}
