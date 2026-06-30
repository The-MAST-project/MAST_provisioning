#requires -Version 5.1
# Stage 2 of the MAST instrument-profiles work: bind the per-unit serial COM
# ports into the live PWI4 .cfg files, AFTER the instruments are connected.
# Run as the `mast` user on a connected unit. Re-runnable and PRESERVATION-SAFE.
#
# Binds only:
#   - EFA focuser   -> EFA.Controller_1.cfg : SerialPort  (the lone generic,
#                      non-PlaneWave USB-serial adapter; brand varies FTDI/Prolific)
#   - PWBus OTA      -> PWBus.StandardOTA.Controller.cfg : SerialPort
#                      (device VID_1CBE&PID_0002)
# Leaves alone (auto-detected, not COM-bound here): the Elmo mount (PWI4 usb
# auto-detect) and the FCU/Standa stage (MAST_unit libximc auto-discovery).
# NEVER touches focuser calibration, the pointing model, or mount-firmware tuning.
#
# Safety:
#   -DryRun  : report only, writes NOTHING (allowed even while PWI4 is running).
#   default  : writes a SerialPort line ONLY when the current value is empty, or
#              points at a COM that is not currently present (stale). A binding
#              that already matches the detected device, or points at a different
#              but PRESENT COM, is left untouched unless -Force is given. A real
#              (non-DryRun) run refuses to start while PWI4 is open, because PWI4
#              rewrites its .cfg on exit.
[CmdletBinding()]
param(
    [string]${Pwi4Settings} = (Join-Path ${env:USERPROFILE} 'Documents\PlaneWave Instruments\PWI4\Settings'),
    # Operator override for the EFA COM when more than one generic adapter is present.
    [string]${EfaCom} = '',
    # Rebind a target even when its current SerialPort points at a present (but
    # different) COM. Without it, such a binding is preserved.
    [switch]${Force},
    # Report intended actions without writing anything.
    [switch]${DryRun}
)
${ErrorActionPreference} = 'Stop'

${logDir} = Join-Path ${env:SystemDrive} 'MAST\logs'
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} 'calibrate-instruments.log'
${StampDir} = 'C:\ProgramData\MAST\instrument-profiles'

function Log {
    param([string]${Msg}, [string]${Lvl} = 'INFO')
    ${line} = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ${Lvl}, ${Msg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${line}
    Write-Host ${line}
}

function Get-Com { param(${Dev}) if (${Dev}.Name -match '\((COM\d+)\)') { return ${matches}[1] } return $null }

function Set-CfgField {
    # Overwrite "<Field> = <value>" preserving the aligned key prefix. ASCII.
    param([string]${Path}, [string]${Field}, [string]${Value})
    ${re} = '^(\s*' + [regex]::Escape(${Field}) + '\s*=\s*).*$'
    ${found} = $false; ${out} = @()
    foreach (${l} in (Get-Content -LiteralPath ${Path})) {
        if (${l} -match ${re}) { ${found} = $true; ${out} += (${matches}[1] + ${Value}) } else { ${out} += ${l} }
    }
    if (-not ${found}) { ${out} += ('{0} = {1}' -f ${Field}, ${Value}) }
    Set-Content -LiteralPath ${Path} -Value ${out} -Encoding ASCII
}

function Get-CurrentSerialPort {
    param([string]${Path})
    ${cur} = $null
    foreach (${l} in (Get-Content -LiteralPath ${Path})) {
        if (${l} -match '^\s*SerialPort\s*=\s*(\S*)\s*$') { ${cur} = ${matches}[1] }
    }
    return ${cur}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] calibrate-instruments.ps1 started (DryRun={1}, Force={2})" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), [bool]${DryRun}, [bool]${Force})

# Pre-flight: a real run must not fight a running PWI4 (it rewrites cfgs on exit).
${pwi4Running} = [bool](Get-Process -Name pwi4, PWI4 -ErrorAction SilentlyContinue)
if (${pwi4Running} -and -not ${DryRun}) {
    Log 'PWI4 is running. Close it first (it rewrites its .cfg on exit), then re-run. (Use -DryRun to inspect without closing.)' 'ERROR'
    exit 2
}
if (${pwi4Running}) { Log 'NOTE: PWI4 is running; -DryRun is read-only so this is safe.' 'WARN' }
if (-not (Test-Path -LiteralPath ${Pwi4Settings})) { Log ("PWI4 Settings dir not found: {0}" -f ${Pwi4Settings}) 'ERROR'; exit 2 }

# ---- enumerate present serial devices ------------------------------------
${com} = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\(COM\d+\)' }
${presentComs} = @(${com} | ForEach-Object { Get-Com $_ })
Log ("Present COM devices: {0}" -f ((${com} | ForEach-Object { '{0}={1}' -f (Get-Com $_), $_.DeviceID }) -join '  '))

# ---- resolve desired COM per role ----------------------------------------
# PWBus OTA: the VID_1CBE&PID_0002 device.
${pwbusDev} = ${com} | Where-Object { $_.DeviceID -match 'VID_1CBE&PID_0002' } | Select-Object -First 1
${pwbusCom} = if (${pwbusDev}) { Get-Com ${pwbusDev} } else { $null }

# EFA focuser: the lone generic (non-PlaneWave, non-motherboard, non-com0com) adapter.
${generic} = @(${com} | Where-Object {
    $_.DeviceID -notmatch 'VID_1CBE' -and $_.DeviceID -notmatch '^ACPI' -and
    $_.DeviceID -notmatch '^PCI' -and $_.Name -notmatch 'com0com'
})
${efaCom} = $null; ${efaSrc} = ''
if (${EfaCom}) {
    ${efaCom} = ${EfaCom}; ${efaSrc} = 'operator -EfaCom'
} elseif (${generic}.Count -eq 1) {
    ${efaCom} = Get-Com ${generic}[0]; ${efaSrc} = 'lone generic adapter ' + ${generic}[0].DeviceID
} elseif (${generic}.Count -gt 1) {
    Log ("EFA ambiguous: {0} generic serial adapters present -- pass -EfaCom <COMx>. Candidates: {1}" -f ${generic}.Count, ((${generic} | ForEach-Object { '{0}={1}' -f (Get-Com $_), $_.DeviceID }) -join '  ')) 'WARN'
} else {
    Log 'EFA: no generic serial adapter present.' 'WARN'
}

# ---- bind one target -----------------------------------------------------
${results} = @()
function Invoke-Bind {
    param([string]${Name}, [string]${CfgFile}, [string]${DesiredCom}, [string]${Source})
    ${path} = Join-Path ${Pwi4Settings} ${CfgFile}
    if (-not (Test-Path -LiteralPath ${path})) {
        Log ("{0}: {1} absent on this unit -> skip." -f ${Name}, ${CfgFile}) 'WARN'
        return [pscustomobject]@{ Target = ${Name}; Action = 'skip-no-cfg'; Cur = ''; Desired = ${DesiredCom} }
    }
    ${cur} = Get-CurrentSerialPort -Path ${path}
    if (-not ${DesiredCom}) {
        Log ("{0}: device not detected -> leaving SerialPort='{1}'." -f ${Name}, ${cur}) 'WARN'
        return [pscustomobject]@{ Target = ${Name}; Action = 'no-device'; Cur = ${cur}; Desired = '' }
    }
    if (${cur} -eq ${DesiredCom}) {
        Log ("{0}: already correct (SerialPort={1}; {2})." -f ${Name}, ${cur}, ${Source})
        return [pscustomobject]@{ Target = ${Name}; Action = 'already-correct'; Cur = ${cur}; Desired = ${DesiredCom} }
    }
    ${curPresent} = ${cur} -and (${presentComs} -contains ${cur})
    if (${cur} -and ${curPresent} -and -not ${Force}) {
        Log ("{0}: current SerialPort={1} is a PRESENT port but differs from detected {2} ({3}). Preserving; pass -Force to rebind." -f ${Name}, ${cur}, ${DesiredCom}, ${Source}) 'WARN'
        return [pscustomobject]@{ Target = ${Name}; Action = 'preserved-needs-force'; Cur = ${cur}; Desired = ${DesiredCom} }
    }
    ${reason} = if (-not ${cur}) { 'was empty' } elseif (-not ${curPresent}) { "was stale (COM '${cur}' absent)" } else { '-Force' }
    if (${DryRun}) {
        Log ("{0}: WOULD set SerialPort={1} ({2}; {3})." -f ${Name}, ${DesiredCom}, ${reason}, ${Source})
        return [pscustomobject]@{ Target = ${Name}; Action = 'would-bind'; Cur = ${cur}; Desired = ${DesiredCom} }
    }
    Set-CfgField -Path ${path} -Field 'SerialPort' -Value ${DesiredCom}
    Log ("{0}: SET SerialPort={1} ({2}; {3})." -f ${Name}, ${DesiredCom}, ${reason}, ${Source})
    return [pscustomobject]@{ Target = ${Name}; Action = 'bound'; Cur = ${cur}; Desired = ${DesiredCom} }
}

${results} += Invoke-Bind -Name 'EFA focuser' -CfgFile 'EFA.Controller_1.cfg' -DesiredCom ${efaCom} -Source ${efaSrc}
${pwbusSrc} = 'VID_1CBE&PID_0002 ' + $(if (${pwbusDev}) { ${pwbusDev}.DeviceID } else { '(absent)' })
${results} += Invoke-Bind -Name 'PWBus OTA' -CfgFile 'PWBus.StandardOTA.Controller.cfg' -DesiredCom ${pwbusCom} -Source ${pwbusSrc}

# ---- preservation notice + stamp -----------------------------------------
Log 'LEFT UNTOUCHED: Elmo mount (PWI4 usb auto-detect), FCU/Standa (libximc auto), focuser calibration, pointing model, mount-firmware tuning.'

${changed} = @(${results} | Where-Object { $_.Action -eq 'bound' }).Count
if (-not ${DryRun} -and ${changed} -gt 0) {
    New-Item -ItemType Directory -Path ${StampDir} -Force | Out-Null
    ${fp} = ((${com} | Sort-Object DeviceID | ForEach-Object { $_.DeviceID }) -join ';')
    Set-Content -LiteralPath (Join-Path ${StampDir} '.calibrated') -Encoding UTF8 -Value @(
        ("calibrated {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ("device-fingerprint: {0}" -f ${fp})
    )
}

# ---- summary -------------------------------------------------------------
Write-Host ''
Write-Host ('=== calibrate-instruments summary ({0}) ===' -f $(if (${DryRun}) { 'DRY RUN - no changes written' } else { 'applied' }))
foreach (${r} in ${results}) {
    Write-Host ("  {0,-14} {1,-22} cur='{2}' desired='{3}'" -f ${r}.Target, ${r}.Action, ${r}.Cur, ${r}.Desired)
}
exit 0
