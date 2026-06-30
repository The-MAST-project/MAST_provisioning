#requires -Version 5.1
# Verify the instrument-profiles provisioning (provide-instrument-profiles.ps1).
# Asserts the synthesized artifacts are staged and the AtLogon apply task is
# registered. COM-port resolution is best-effort: a missing instrument (e.g. the
# instrument-less dev VM) is reported SKIPPED, not FAIL; a present instrument
# whose SerialPort did not resolve to a COMnn is a FAIL.
[CmdletBinding()]
param(
    # Reserved for parity with other providers' dev-VM escapes; COM checks are
    # already VM-safe (absent device -> skip), so this currently only annotates.
    [switch]${AllowMissingHardware}
)

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off
${verifyLog} = Get-MastVerifyLog -Module 'instrument-profiles'

function W { param([string]${Line}) Add-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), ${Line}) }
Set-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] verify-instrument-profiles.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

${ProfilesRoot} = 'C:\ProgramData\MAST\instrument-profiles'
${Pwi4StageDir} = Join-Path ${ProfilesRoot} 'PWI4\Settings'
${TaskName}     = 'MAST-InstrumentProfiles-Apply'
${ExpectedCfgs} = @(
    'ASCOM.Camera_1.cfg', 'EFA.Controller_1.cfg', 'EFA.Hedrick.Focuser_1.cfg',
    'Elmo.Controller.cfg', 'Elmo.L500.Mount.cfg', 'GUI.cfg',
    'PWBus.StandardOTA.Controller.cfg', 'PWI4.cfg', 'Telemetry.cfg', 'TempManager.cfg'
)
${ComChecks} = @(
    @{ Role = 'EFA focuser'; Vid = 'VID_0403'; Pid = 'PID_6001'; Cfg = 'EFA.Controller_1.cfg';             Field = 'SerialPort' },
    @{ Role = 'PWBus OTA';   Vid = 'VID_1CBE'; Pid = 'PID_0002'; Cfg = 'PWBus.StandardOTA.Controller.cfg'; Field = 'SerialPort' }
)

${fail} = @()

# 1) All expected cfgs staged.
foreach (${c} in ${ExpectedCfgs}) {
    ${p} = Join-Path ${Pwi4StageDir} ${c}
    if (Test-Path -LiteralPath ${p}) { W ("cfg present: {0}" -f ${c}) }
    else { ${fail} += ("missing staged cfg: {0}" -f ${c}) }
}

# 2) PWI4.cfg location fields numeric.
${pwi4} = Join-Path ${Pwi4StageDir} 'PWI4.cfg'
if (Test-Path -LiteralPath ${pwi4}) {
    ${content} = Get-Content -LiteralPath ${pwi4} -Raw
    foreach (${k} in 'Latitude', 'Longitude', 'HeightMeters') {
        ${m} = [regex]::Match(${content}, ('(?m)^\s*{0}\s*=\s*(-?\d+(\.\d+)?)\s*$' -f ${k}))
        if (${m}.Success) { W ("{0} = {1}" -f ${k}, ${m}.Groups[1].Value) }
        else { ${fail} += ("PWI4.cfg {0} not numeric / missing" -f ${k}) }
    }
}

# 3) PHD2 reg staged.
${reg} = Join-Path ${ProfilesRoot} 'phd2_profiles.reg'
if (Test-Path -LiteralPath ${reg}) { W ("PHD2 reg staged: {0}" -f ${reg}) }
else { ${fail} += "missing staged phd2_profiles.reg" }

# 4) AtLogon apply task registered.
if (Get-ScheduledTask -TaskName ${TaskName} -ErrorAction SilentlyContinue) { W ("apply task registered: {0}" -f ${TaskName}) }
else { ${fail} += ("apply task not registered: {0}" -f ${TaskName}) }

# 5) COM resolution (best-effort; absent device -> SKIP).
${comDevices} = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\(COM\d+\)' }
foreach (${e} in ${ComChecks}) {
    ${present} = ${comDevices} | Where-Object { $_.DeviceID -match ${e}.Vid -and $_.DeviceID -match ${e}.Pid } | Select-Object -First 1
    ${cfgPath} = Join-Path ${Pwi4StageDir} ${e}.Cfg
    ${resolved} = $false
    if (Test-Path -LiteralPath ${cfgPath}) {
        ${cc} = Get-Content -LiteralPath ${cfgPath} -Raw
        if (${cc} -match ('(?m)^\s*{0}\s*=\s*(COM\d+)\s*$' -f ${e}.Field)) { ${resolved} = ${matches}[1] }
    }
    if (${present}) {
        if (${resolved}) { W ("COM OK: {0} {1}:{2} = {3}" -f ${e}.Role, ${e}.Cfg, ${e}.Field, ${resolved}) }
        else { ${fail} += ("{0} device present but {1}:{2} did not resolve to a COM port" -f ${e}.Role, ${e}.Cfg, ${e}.Field) }
    } else {
        W ("SKIP (pending-hardware): {0} ({1}/{2}) not present on this machine" -f ${e}.Role, ${e}.Vid, ${e}.Pid)
    }
}

if (${fail}.Count -eq 0) {
    W 'PASS instrument-profiles staged + apply task registered'
    Write-MastSmokeOk -Module 'instrument-profiles' | Out-Null
    exit 0
}
W ('FAIL ' + (${fail} -join '; '))
exit 1
