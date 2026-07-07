#requires -Version 5.1
# Phase 2 (first mast logon, mast user context): copy the synthesized PWI4 .cfg
# files into the mast user's PWI4 Settings dir and import the PHD2 profiles into
# HKCU. One-shot: guarded by a sentinel and self-unregisters its AtLogon task.
# Registered by provide-instrument-profiles.ps1 (phase 1, provisioning).
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${ProfilesRoot} = 'C:\ProgramData\MAST\instrument-profiles'
${Sentinel}     = Join-Path ${ProfilesRoot} '.applied'
${LogFile}      = Join-Path ${ProfilesRoot} 'apply.log'
${TaskName}     = 'MAST-InstrumentProfiles-Apply'

function Log {
    param([string]${Line})
    Add-Content -LiteralPath ${LogFile} -Encoding UTF8 -Value ("[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ${env:USERNAME}, ${Line})
}

try {
    if (Test-Path -LiteralPath ${Sentinel}) {
        Log 'Profiles already applied (sentinel present); nothing to do.'
        Unregister-ScheduledTask -TaskName ${TaskName} -ErrorAction SilentlyContinue -Confirm:$false
        exit 0
    }

    # PWI4 .cfg -> mast Documents PWI4 Settings dir.
    ${srcCfgDir} = Join-Path ${ProfilesRoot} 'PWI4\Settings'
    ${dstCfgDir} = Join-Path ${env:USERPROFILE} 'Documents\PlaneWave Instruments\PWI4\Settings'
    New-Item -ItemType Directory -Path ${dstCfgDir} -Force | Out-Null
    Copy-Item -Path (Join-Path ${srcCfgDir} '*.cfg') -Destination ${dstCfgDir} -Force
    Log ("Copied PWI4 cfgs -> {0}" -f ${dstCfgDir})

    # PHD2 profiles -> HKCU (we are running as the mast user, so HKCU is mast's).
    ${reg} = Join-Path ${ProfilesRoot} 'phd2_profiles.reg'
    if (Test-Path -LiteralPath ${reg}) {
        ${p} = Start-Process -FilePath 'reg.exe' -ArgumentList @('import', ${reg}) -Wait -PassThru -NoNewWindow
        if (${p}.ExitCode -ne 0) { throw ("reg import failed (exit {0}) for {1}" -f ${p}.ExitCode, ${reg}) }
        Log ("Imported PHD2 profiles from {0} into HKCU." -f ${reg})
    } else {
        Log ("[WARN] {0} missing; skipped PHD2 import." -f ${reg})
    }

    Set-Content -LiteralPath ${Sentinel} -Encoding UTF8 -Value ("applied {0} by {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ${env:USERNAME})
    Unregister-ScheduledTask -TaskName ${TaskName} -ErrorAction SilentlyContinue -Confirm:$false
    Log 'Apply complete; task unregistered.'
    exit 0
}
catch {
    Log ("FAILED: {0}" -f $_)
    exit 1
}
