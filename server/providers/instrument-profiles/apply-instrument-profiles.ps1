#requires -Version 5.1
# Phase 2 (first mast logon, mast user context): copy the synthesized PWI4 .cfg
# files into the mast user's PWI4 Settings dir and import the PHD2 profiles into
# HKCU. One-shot: guarded by a sentinel and self-unregisters its AtLogon task.
# Registered by provide-instrument-profiles.ps1 (phase 1, provisioning).
#
# Never overwrites. A live .cfg is left as it is and only a missing one is copied;
# the PHD2 profiles are imported only when the mast user has none. A unit whose
# sentinel was lost to an older provide (which deleted the staging dir) therefore
# keeps its calibrated COM bindings and PHD2 tuning when this runs again.
[CmdletBinding()]
param(
    # Overridable so the script can be exercised against planted files (server/tests).
    [string]${ProfilesRoot} = 'C:\ProgramData\MAST\instrument-profiles',
    [string]${DestCfgDir} = (Join-Path ${env:USERPROFILE} 'Documents\PlaneWave Instruments\PWI4\Settings'),
    [string]${Phd2ProfilesKey} = 'HKCU:\Software\StarkLabs\PHDGuidingV2\profile',
    [string]${TaskName} = 'MAST-InstrumentProfiles-Apply'
)

${ErrorActionPreference} = 'Stop'
${Sentinel}     = Join-Path ${ProfilesRoot} '.applied'
${LogFile}      = Join-Path ${ProfilesRoot} 'apply.log'

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

    # PWI4 .cfg -> mast Documents PWI4 Settings dir, only where none exists yet.
    ${srcCfgDir} = Join-Path ${ProfilesRoot} 'PWI4\Settings'
    New-Item -ItemType Directory -Path ${DestCfgDir} -Force | Out-Null
    foreach (${cfg} in (Get-ChildItem -LiteralPath ${srcCfgDir} -Filter '*.cfg' -File)) {
        ${dst} = Join-Path ${DestCfgDir} ${cfg}.Name
        if (Test-Path -LiteralPath ${dst}) {
            Log ("Kept live {0}; the template was not copied over it." -f ${dst})
        } else {
            Copy-Item -LiteralPath ${cfg}.FullName -Destination ${dst}
            Log ("Copied {0} -> {1}" -f ${cfg}.Name, ${DestCfgDir})
        }
    }

    # PHD2 profiles -> HKCU (we are running as the mast user, so HKCU is mast's), only
    # when there are none: an import rewrites every profile key the .reg names.
    ${existing} = @()
    if (Test-Path -LiteralPath ${Phd2ProfilesKey}) { ${existing} = @(Get-ChildItem -LiteralPath ${Phd2ProfilesKey}) }
    ${reg} = Join-Path ${ProfilesRoot} 'phd2_profiles.reg'
    if (${existing}.Count -gt 0) {
        Log ("Kept {0} existing PHD2 profile(s) under {1}; {2} was not imported." -f ${existing}.Count, ${Phd2ProfilesKey}, ${reg})
    } elseif (Test-Path -LiteralPath ${reg}) {
        # Not -Wait: Windows PowerShell's Start-Process -Wait -PassThru can return a null
        # ExitCode, which reads as a failure. Holding the handle keeps the exit code.
        ${p} = Start-Process -FilePath 'reg.exe' -ArgumentList @('import', ('"{0}"' -f ${reg})) -PassThru -NoNewWindow
        ${null} = ${p}.Handle
        ${p}.WaitForExit()
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
