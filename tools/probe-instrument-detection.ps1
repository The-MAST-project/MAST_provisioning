#requires -Version 5.1
# Phase-0 hardware probe for the instrument-calibration design. READ-ONLY by
# default: enumerates the unit's serial devices, classifies them by USB
# InstanceId (VID/PID/MI) against the known MAST role table, and cross-checks
# what PWI4's live .cfg files currently point at (flagging stale/absent COM
# bindings). Run as the `mast` user on a CONNECTED unit (mastw or mast02).
#
# It answers, from real hardware:
#   Q2  Is the EFA reliably "the one generic (non-1CBE) USB-serial adapter"?
#   (data for Q1) Which devices are present and what COM did each enumerate to?
#
# The PWI4 auto-detect experiment (Q1) mutates config, so it is gated behind
# -StageAutoDetectExperiment (backs up first) with a -RestoreBackup undo. The
# default run changes nothing.
[CmdletBinding()]
param(
    # Back up EFA/PWBus cfgs and blank their SerialPort so you can launch PWI4 and
    # see whether it auto-detects them over USB (like it does the Elmo mount).
    [switch]${StageAutoDetectExperiment},
    # Restore the most recent backup taken by -StageAutoDetectExperiment.
    [switch]${RestoreBackup}
)
${ErrorActionPreference} = 'Stop'

${Pwi4Settings} = Join-Path ${env:USERPROFILE} 'Documents\PlaneWave Instruments\PWI4\Settings'
${BackupRoot}   = Join-Path ${env:USERPROFILE} 'Documents\PlaneWave Instruments\PWI4\Settings-probe-backup'

# Known MAST instrument role table (from the mast00/02/w cross-unit comparison).
# EFA is intentionally NOT keyed on a fixed VID/PID -- its adapter brand varies
# (FTDI vs Prolific); it is inferred as the lone non-PlaneWave serial adapter.
${Roles} = @(
    @{ Role = 'PWBus OTA (serial)'; Match = { param($d) $d.DeviceID -match 'VID_1CBE&PID_0002' };                    Cfg = 'PWBus.StandardOTA.Controller.cfg'; Field = 'SerialPort' },
    @{ Role = 'Mount Axis1';        Match = { param($d) $d.DeviceID -match 'VID_1CBE&PID_0267' -and $d.DeviceID -match 'MI_00' }; Cfg = '(auto-detect; usb)'; Field = '' },
    @{ Role = 'Mount Axis2';        Match = { param($d) $d.DeviceID -match 'VID_1CBE&PID_0267' -and $d.DeviceID -match 'MI_02' }; Cfg = '(auto-detect; usb)'; Field = '' },
    @{ Role = 'FCU stage (Standa)'; Match = { param($d) $d.DeviceID -match 'VID_1CBE&PID_0007' };                    Cfg = '(MAST_unit libximc auto)'; Field = '' }
)

function Get-Com { param($d) if ($d.Name -match '\((COM\d+)\)') { return ${matches}[1] } return '?' }

# ---- RestoreBackup -------------------------------------------------------
if (${RestoreBackup}) {
    if (-not (Test-Path -LiteralPath ${BackupRoot})) { throw "no probe backup at ${BackupRoot}" }
    Copy-Item -Path (Join-Path ${BackupRoot} '*.cfg') -Destination ${Pwi4Settings} -Force
    Write-Host ("Restored EFA/PWBus cfgs from {0}" -f ${BackupRoot})
    return
}

# ---- Enumerate present serial devices ------------------------------------
${comDevices} = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\(COM\d+\)' }
Write-Host '=== Present serial (COM) devices ==='
${comDevices} | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-8} | {1,-34} | {2}" -f (Get-Com $_), $_.Name, $_.DeviceID) }

# ---- Classify by role ----------------------------------------------------
Write-Host ''
Write-Host '=== Role classification (known MAST devices) ==='
${planewaveSerials} = @()
foreach (${r} in ${Roles}) {
    ${hit} = ${comDevices} | Where-Object { & ${r}.Match $_ } | Select-Object -First 1
    if (${hit}) {
        ${planewaveSerials} += ${hit}.DeviceID
        Write-Host ("  {0,-22} -> {1,-7}  cfg target: {2} {3}" -f ${r}.Role, (Get-Com ${hit}), ${r}.Cfg, ${r}.Field)
    } else {
        Write-Host ("  {0,-22} -> (not present)" -f ${r}.Role)
    }
}

# ---- Q2: is EFA the lone non-PlaneWave generic serial adapter? -----------
Write-Host ''
Write-Host '=== EFA inference (Q2): generic (non-1CBE, non-motherboard) USB-serial adapters ==='
${generic} = ${comDevices} | Where-Object {
    $_.DeviceID -notmatch 'VID_1CBE' -and $_.DeviceID -notmatch '^ACPI' -and $_.DeviceID -notmatch '^PCI'
}
if (${generic}) {
    ${generic} | ForEach-Object { Write-Host ("  {0,-8} | {1,-34} | {2}" -f (Get-Com $_), $_.Name, $_.DeviceID) }
    if ((${generic} | Measure-Object).Count -eq 1) {
        Write-Host '  => exactly ONE generic adapter: EFA inference is SAFE on this unit.'
    } else {
        Write-Host '  => MORE THAN ONE generic adapter: EFA needs operator confirmation (cannot auto-pick).'
    }
} else {
    Write-Host '  => none present (EFA adapter not connected on this unit).'
}

# ---- Cross-check live PWI4 cfgs (flag stale/absent bindings) --------------
Write-Host ''
Write-Host '=== Live PWI4 cfg SerialPort vs present COM ports ==='
${presentComs} = ${comDevices} | ForEach-Object { Get-Com $_ }
foreach (${cf} in 'EFA.Controller_1.cfg', 'PWBus.StandardOTA.Controller.cfg') {
    ${p} = Join-Path ${Pwi4Settings} ${cf}
    if (-not (Test-Path -LiteralPath ${p})) { Write-Host ("  {0}: (absent)" -f ${cf}); continue }
    ${c} = Get-Content -LiteralPath ${p} -Raw
    if (${c} -match '(?m)^\s*SerialPort\s*=\s*(COM\d+)') {
        ${cfgCom} = ${matches}[1]
        ${state} = if (${presentComs} -contains ${cfgCom}) { 'present' } else { 'ABSENT (stale binding)' }
        Write-Host ("  {0,-34} SerialPort={1,-6} [{2}]" -f ${cf}, ${cfgCom}, ${state})
    } else {
        Write-Host ("  {0,-34} SerialPort=<unset>" -f ${cf})
    }
}

# ---- Q1: stage the PWI4 auto-detect experiment ---------------------------
if (${StageAutoDetectExperiment}) {
    Write-Host ''
    Write-Host '=== Staging PWI4 auto-detect experiment (Q1) ==='
    if (Test-Path -LiteralPath ${BackupRoot}) { Remove-Item -LiteralPath ${BackupRoot} -Recurse -Force }
    New-Item -ItemType Directory -Path ${BackupRoot} -Force | Out-Null
    foreach (${cf} in 'EFA.Controller_1.cfg', 'PWBus.StandardOTA.Controller.cfg') {
        ${p} = Join-Path ${Pwi4Settings} ${cf}
        if (-not (Test-Path -LiteralPath ${p})) { continue }
        Copy-Item -LiteralPath ${p} -Destination ${BackupRoot} -Force
        # Blank the explicit SerialPort to force PWI4 to fall back to detection.
        ${lines} = Get-Content -LiteralPath ${p} | ForEach-Object {
            if ($_ -match '^(\s*SerialPort\s*=\s*).*$') { ${matches}[1] } else { $_ }
        }
        Set-Content -LiteralPath ${p} -Value ${lines} -Encoding ASCII
    }
    Write-Host ("  Backed up to {0}; blanked SerialPort in EFA + PWBus cfgs." -f ${BackupRoot})
    Write-Host '  NOW: launch PWI4, try Connect on the focuser + mirror cover, note whether'
    Write-Host '       they connect WITHOUT an explicit COM (i.e. PWI4 auto-detected them).'
    Write-Host '  THEN: re-run this script with -RestoreBackup to revert.'
}
