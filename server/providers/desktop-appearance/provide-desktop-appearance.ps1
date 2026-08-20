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
${TaskNeverRan}     = 267011  # 0x41303, SCHED_S_TASK_HAS_NOT_RUN
${ApplyWaitSeconds} = 60
${ApplyPollSeconds} = 2

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

    # 2) Stage the renderer and the apply script at a persistent path. The AtLogon
    #    task runs long after the staging dir is gone, and the renderer follows it
    #    so a re-render on a unit needs no payload.
    # The lib travels with them: apply-desktop-appearance.ps1 dot-sources it for the
    # value table, and it runs from this path at every logon long after the staging
    # directory is gone.
    foreach (${name} in @('render-desktop-background.ps1', 'apply-desktop-appearance.ps1', 'mast-appearance-lib.ps1')) {
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
        -Coordinates (${fields}.coordinates)
    foreach (${artifact} in @(${imagePath}, ${sidecarPath})) {
        if (-not (Test-Path -LiteralPath ${artifact})) { throw ("render-desktop-background.ps1 produced no {0}" -f ${artifact}) }
    }
    Write-AppearanceLog ("Rendered background for {0} -> {1}" -f ${env:COMPUTERNAME}, ${imagePath})

    # 4) Write the per-user values into mast's hive. A machine where mast has never
    #    signed in has no profile yet: nothing to write, and the AtLogon task is
    #    what covers it.
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

            # Wait for it, and fail if it failed. Starting a task and reporting success
            # regardless would make this module's exit code meaningless: the whole
            # visible outcome -- a repainted desktop -- happens in that task, and its
            # exit code is the only trace it leaves. Waiting also removes a race, since
            # the verify step reads the same LastTaskResult moments later and would
            # otherwise catch the task mid-run.
            ${waited} = 0
            while (${waited} -lt ${ApplyWaitSeconds}) {
                ${state} = (Get-ScheduledTask -TaskName ${TaskName} -ErrorAction SilentlyContinue).State
                if (${state} -ne 'Running') { break }
                Start-Sleep -Seconds ${ApplyPollSeconds}
                ${waited} = ${waited} + ${ApplyPollSeconds}
            }
            ${applyInfo} = Get-ScheduledTaskInfo -TaskName ${TaskName} -ErrorAction SilentlyContinue
            if (-not ${applyInfo}) {
                Write-AppearanceLog '[WARN] apply task run info unreadable; its outcome is unknown.'
            } elseif (${applyInfo}.LastTaskResult -eq ${TaskNeverRan}) {
                Write-AppearanceLog ("[WARN] apply task still reports not-yet-run after {0}s; its outcome is unknown." -f ${waited})
            } elseif (${applyInfo}.LastTaskResult -ne 0) {
                throw ("the apply task failed (result {0}); the desktop was not repainted -- see {1}" -f ${applyInfo}.LastTaskResult, (Join-Path ${AppearanceRoot} 'apply.log'))
            } else {
                Write-AppearanceLog 'Apply task completed cleanly; the live desktop is updated.'
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
