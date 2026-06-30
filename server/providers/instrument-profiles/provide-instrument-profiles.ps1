#requires -Version 5.1
# Phase 1 (provisioning, SYSTEM context): synthesize the PWI4 .cfg + PHD2 .reg
# instrument profiles into the machine-readable staging dir
# C:\ProgramData\MAST\instrument-profiles, then register an AtLogon scheduled
# task that applies them into the mast user's profile on first sign-in (phase 2,
# apply-instrument-profiles.ps1). Phase 2 is needed because the per-user mast
# profile (Documents dir + HKCU hive) is not materialized at provisioning time.
#
# Per-unit synthesis:
#   - PWI4.cfg Latitude/Longitude/HeightMeters <- C:\WIS\unit.toml [location].
#   - EFA / PWBus SerialPort <- COM port reverse-located from the device USB
#     InstanceID (VID/PID) via Win32_PnPEntity. Absent device -> template value
#     left in place and logged as pending-hardware (e.g. the instrument-less VM).
#   - Mount (Elmo) config shipped verbatim from MAST02 (no per-unit COM yet).
[CmdletBinding()]
param(
    [string]${AssetsRoot} = '.',
    # Staging dir for the synthesized artifacts. Overridable so the synthesis can
    # be exercised on real hardware (mast02) against a temp dir without touching
    # the live profile staging.
    [string]${ProfilesRoot} = 'C:\ProgramData\MAST\instrument-profiles',
    # Bootstrap config the site location is read from (deployed by config-bootstrap).
    [string]${UnitToml} = 'C:\WIS\unit.toml',
    # Skip the AtLogon apply-task registration (non-destructive synthesis tests).
    [switch]${SkipTask}
)

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
${logFile} = Join-Path ${logDir} 'instrument-profiles.log'

function Log {
    param([string]${Line})
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-instrument-profiles.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# --- constants -------------------------------------------------------------
${Pwi4StageDir} = Join-Path ${ProfilesRoot} 'PWI4\Settings'
${TaskName}     = 'MAST-InstrumentProfiles-Apply'
${MastUser}     = 'mast'

# Role -> COM-bearing cfg. Each instrument is keyed on its stable USB InstanceID
# (VID+PID); the live COM number is enumerated and written into <Field>.
${ComMap} = @(
    @{ Role = 'EFA focuser'; Vid = 'VID_0403'; Pid = 'PID_6001'; Cfg = 'EFA.Controller_1.cfg';             Field = 'SerialPort' },
    @{ Role = 'PWBus OTA';   Vid = 'VID_1CBE'; Pid = 'PID_0002'; Cfg = 'PWBus.StandardOTA.Controller.cfg'; Field = 'SerialPort' }
)

# --- helpers ---------------------------------------------------------------
function Set-CfgField {
    # Overwrite "<Field> = <value>" in an aligned PWI4 .cfg, preserving the
    # leading key + padding so the file stays visually aligned. Appends the key
    # if it is absent. PWI4 cfgs are ASCII.
    param(
        [Parameter(Mandatory)][string]${Path},
        [Parameter(Mandatory)][string]${Field},
        [Parameter(Mandatory)][string]${Value}
    )
    ${re} = '^(\s*' + [regex]::Escape(${Field}) + '\s*=\s*).*$'
    ${found} = $false
    ${out} = @()
    foreach (${line} in (Get-Content -LiteralPath ${Path})) {
        if (${line} -match ${re}) {
            ${found} = $true
            ${out} += (${matches}[1] + ${Value})
        } else {
            ${out} += ${line}
        }
    }
    if (-not ${found}) { ${out} += ('{0} = {1}' -f ${Field}, ${Value}) }
    Set-Content -LiteralPath ${Path} -Value ${out} -Encoding ASCII
}

function Get-TomlValue {
    # Light single-key reader for the flat / single-section unit.toml. No tomllib
    # dependency (mirrors verify-config-bootstrap's regex approach).
    param([Parameter(Mandatory)][string]${Content}, [Parameter(Mandatory)][string]${Key})
    ${m} = [regex]::Match(${Content}, ('(?m)^\s*{0}\s*=\s*(.+?)\s*$' -f [regex]::Escape(${Key})))
    if (${m}.Success) { return ${m}.Groups[1].Value.Trim().Trim('"') }
    return $null
}

try {
    # 1) Extract the asset bundle into the machine staging dir.
    ${zip} = Join-Path ${AssetsRoot} 'instrument-profiles-assets.zip'
    if (-not (Test-Path -LiteralPath ${zip})) { ${zip} = Join-Path ${PSScriptRoot} 'instrument-profiles-assets.zip' }
    if (-not (Test-Path -LiteralPath ${zip})) { throw "asset bundle not found: instrument-profiles-assets.zip" }

    if (Test-Path -LiteralPath ${ProfilesRoot}) { Remove-Item -LiteralPath ${ProfilesRoot} -Recurse -Force }
    New-Item -ItemType Directory -Path ${ProfilesRoot} -Force | Out-Null
    Expand-Archive -LiteralPath ${zip} -DestinationPath ${ProfilesRoot} -Force
    Log ("Extracted profile bundle to {0}" -f ${ProfilesRoot})

    # 2) Site location from the deployed bootstrap config (single source of truth).
    ${pwi4Cfg} = Join-Path ${Pwi4StageDir} 'PWI4.cfg'
    if (Test-Path -LiteralPath ${UnitToml}) {
        ${toml} = Get-Content -LiteralPath ${UnitToml} -Raw
        ${lat} = Get-TomlValue -Content ${toml} -Key 'latitude'
        ${lon} = Get-TomlValue -Content ${toml} -Key 'longitude'
        ${elev} = Get-TomlValue -Content ${toml} -Key 'elevation'
        if (${lat} -and ${lon} -and ${elev}) {
            Set-CfgField -Path ${pwi4Cfg} -Field 'Latitude'    -Value ${lat}
            Set-CfgField -Path ${pwi4Cfg} -Field 'Longitude'   -Value ${lon}
            Set-CfgField -Path ${pwi4Cfg} -Field 'HeightMeters' -Value ${elev}
            Log ("PWI4 location set from {0}: lat={1} lon={2} height={3}" -f ${UnitToml}, ${lat}, ${lon}, ${elev})
        } else {
            Log ("[WARN] {0} present but [location] keys incomplete; PWI4 location left at template values." -f ${UnitToml})
        }
    } else {
        Log ("[WARN] {0} absent (config-bootstrap not run?); PWI4 location left at template (MAST02) values." -f ${UnitToml})
    }

    # 3) COM-port reverse-lookup from USB InstanceID.
    ${comDevices} = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\(COM\d+\)' }
    foreach (${entry} in ${ComMap}) {
        ${cfgPath} = Join-Path ${Pwi4StageDir} ${entry}.Cfg
        ${dev} = ${comDevices} | Where-Object {
            $_.DeviceID -match ${entry}.Vid -and $_.DeviceID -match ${entry}.Pid
        } | Select-Object -First 1
        if (${dev} -and ${dev}.Name -match '\((COM\d+)\)') {
            ${com} = ${matches}[1]
            Set-CfgField -Path ${cfgPath} -Field ${entry}.Field -Value ${com}
            Log ("{0}: {1} {2}\{3} -> {4}:{5} = {6}" -f ${entry}.Role, ${entry}.Vid, ${entry}.Pid, ${dev}.DeviceID, ${entry}.Cfg, ${entry}.Field, ${com})
        } else {
            Log ("[pending-hardware] {0} ({1}/{2}) not present; {3}:{4} left at template value." -f ${entry}.Role, ${entry}.Vid, ${entry}.Pid, ${entry}.Cfg, ${entry}.Field)
        }
    }

    # 4) Make the phase-2 apply script available at a persistent path (the AtLogon
    #    task runs long after the staging dir is gone).
    ${applySrc} = Join-Path ${PSScriptRoot} 'apply-instrument-profiles.ps1'
    if (-not (Test-Path -LiteralPath ${applySrc})) { ${applySrc} = Join-Path ${AssetsRoot} 'apply-instrument-profiles.ps1' }
    if (-not (Test-Path -LiteralPath ${applySrc})) { throw "apply-instrument-profiles.ps1 not found for staging" }
    ${applyDst} = Join-Path ${ProfilesRoot} 'apply-instrument-profiles.ps1'
    Copy-Item -LiteralPath ${applySrc} -Destination ${applyDst} -Force
    Log ("Staged phase-2 apply script: {0}" -f ${applyDst})

    # 5) Register the AtLogon task that applies the profiles into the mast user's
    #    profile on first sign-in (copies cfgs into Documents, imports the PHD2
    #    HKCU profiles). Runs as the mast user, non-elevated, in the logon session.
    if (-not ${SkipTask}) {
        ${argLine} = ('-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "{0}"' -f ${applyDst})
        ${action} = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ${argLine}
        ${trigger} = New-ScheduledTaskTrigger -AtLogOn -User ${MastUser}
        ${principal} = New-ScheduledTaskPrincipal -UserId ${MastUser} -LogonType Interactive -RunLevel Limited
        ${settings} = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Unregister-ScheduledTask -TaskName ${TaskName} -ErrorAction SilentlyContinue -Confirm:$false
        Register-ScheduledTask -TaskName ${TaskName} `
            -Description 'Apply MAST PWI4 + PHD2 instrument profiles into the mast user profile on first logon (one-shot; self-unregisters).' `
            -Action ${action} -Trigger ${trigger} -Principal ${principal} -Settings ${settings} -ErrorAction Stop | Out-Null
        Log ("Registered AtLogon apply task '{0}' for user '{1}'." -f ${TaskName}, ${MastUser})
    } else {
        Log 'SkipTask set; skipped AtLogon apply-task registration (synthesis-only test mode).'
    }

    # 6) Smoke marker.
    Write-MastSmokeOk -Module 'instrument-profiles' | Out-Null
    Log 'instrument-profiles provisioning complete.'
    exit 0
}
catch {
    Log ("FAILED: {0}" -f $_)
    exit 1
}
