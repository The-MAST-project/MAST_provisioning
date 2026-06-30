#requires -Version 5.1
# Stage 2 of the MAST instrument-profiles work: bind the per-unit serial COM
# ports into the live PWI4 .cfg files, AFTER the instruments are connected.
# Run as the `mast` user on a connected unit. Re-runnable and PRESERVATION-SAFE.
#
# Two ways to run:
#   -Interactive : operator menu (view state / dry run / apply / force). Launched
#                  from the "MAST Instrument Calibration" desktop shortcut.
#   CLI          : -DryRun / -Force / -EfaCom for scripted/headless use.
#
# Binds only:
#   - EFA focuser  -> EFA.Controller_1.cfg : SerialPort  (the lone generic,
#                     non-PlaneWave USB-serial adapter; brand varies FTDI/Prolific)
#   - PWBus OTA     -> PWBus.StandardOTA.Controller.cfg : SerialPort (VID_1CBE&PID_0002)
# Leaves alone: the Elmo mount (PWI4 usb auto-detect) and the FCU/Standa stage
# (MAST_unit libximc auto). NEVER touches focuser calibration, the pointing
# model, or mount-firmware tuning.
#
# Safety: a real (writing) run requires PWI4 to be CLOSED (PWI4 rewrites its .cfg
# on exit). Viewing/dry-run never write and are allowed while PWI4 runs. A write
# happens only when the current SerialPort is empty or stale (points at an absent
# COM); a present-but-different binding is preserved unless -Force.
[CmdletBinding()]
param(
    [string]${Pwi4Settings} = (Join-Path ${env:USERPROFILE} 'Documents\PlaneWave Instruments\PWI4\Settings'),
    [string]${EfaCom} = '',
    [switch]${Force},
    [switch]${DryRun},
    [switch]${Interactive}
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
}

function Get-Com { param(${Dev}) if (${Dev}.Name -match '\((COM\d+)\)') { return ${matches}[1] } return $null }

function Set-CfgField {
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

function Test-Pwi4Running { [bool](Get-Process -Name pwi4, PWI4 -ErrorAction SilentlyContinue) }

# Resolve the detected COM per role from the present USB-serial devices.
function Resolve-State {
    ${com} = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\(COM\d+\)' }
    ${present} = @(${com} | ForEach-Object { Get-Com $_ })
    ${pwbusDev} = ${com} | Where-Object { $_.DeviceID -match 'VID_1CBE&PID_0002' } | Select-Object -First 1
    ${generic} = @(${com} | Where-Object {
        $_.DeviceID -notmatch 'VID_1CBE' -and $_.DeviceID -notmatch '^ACPI' -and
        $_.DeviceID -notmatch '^PCI' -and $_.Name -notmatch 'com0com'
    })
    ${efaCom} = $null; ${efaSrc} = ''
    if (${EfaCom}) { ${efaCom} = ${EfaCom}; ${efaSrc} = 'operator -EfaCom' }
    elseif (${generic}.Count -eq 1) { ${efaCom} = Get-Com ${generic}[0]; ${efaSrc} = 'lone generic adapter ' + ${generic}[0].DeviceID }
    elseif (${generic}.Count -gt 1) { ${efaSrc} = ("AMBIGUOUS: {0} generic adapters -- pass -EfaCom <COMx>. {1}" -f ${generic}.Count, ((${generic} | ForEach-Object { '{0}={1}' -f (Get-Com $_), $_.DeviceID }) -join '  ')) }
    else { ${efaSrc} = 'no generic serial adapter present' }
    return [pscustomobject]@{
        Devices = ${com}; Present = ${present}
        EfaCom = ${efaCom}; EfaSrc = ${efaSrc}
        PwbusCom = $(if (${pwbusDev}) { Get-Com ${pwbusDev} } else { $null })
        PwbusSrc = $(if (${pwbusDev}) { 'VID_1CBE&PID_0002 ' + ${pwbusDev}.DeviceID } else { 'device not present' })
        Pwi4Running = (Test-Pwi4Running)
    }
}

# Compute (without writing) what would happen to one target.
function Get-TargetPlan {
    param([string]${Name}, [string]${CfgFile}, [string]${DesiredCom}, [string]${Source}, [bool]${DoForce}, ${Present})
    ${path} = Join-Path ${Pwi4Settings} ${CfgFile}
    ${o} = [pscustomobject]@{ Target = ${Name}; CfgFile = ${CfgFile}; Path = ${path}; Cur = ''; Desired = ${DesiredCom}; Source = ${Source}; Action = ''; Reason = ''; WillWrite = $false }
    if (-not (Test-Path -LiteralPath ${path})) { ${o}.Action = 'skip-no-cfg'; return ${o} }
    ${o}.Cur = Get-CurrentSerialPort -Path ${path}
    if (-not ${DesiredCom}) { ${o}.Action = 'no-device'; return ${o} }
    if (${o}.Cur -eq ${DesiredCom}) { ${o}.Action = 'already-correct'; return ${o} }
    ${curPresent} = ${o}.Cur -and (${Present} -contains ${o}.Cur)
    if (${o}.Cur -and ${curPresent} -and -not ${DoForce}) { ${o}.Action = 'preserved-needs-force'; return ${o} }
    ${o}.Reason = if (-not ${o}.Cur) { 'was empty' } elseif (-not ${curPresent}) { ("was stale (COM '{0}' absent)" -f ${o}.Cur) } else { '-Force' }
    ${o}.Action = 'would-bind'; ${o}.WillWrite = $true
    return ${o}
}

function Build-Plan {
    param([bool]${DoForce})
    ${st} = Resolve-State
    ${plans} = @(
        (Get-TargetPlan -Name 'EFA focuser' -CfgFile 'EFA.Controller_1.cfg' -DesiredCom ${st}.EfaCom -Source ${st}.EfaSrc -DoForce ${DoForce} -Present ${st}.Present),
        (Get-TargetPlan -Name 'PWBus OTA' -CfgFile 'PWBus.StandardOTA.Controller.cfg' -DesiredCom ${st}.PwbusCom -Source ${st}.PwbusSrc -DoForce ${DoForce} -Present ${st}.Present)
    )
    return [pscustomobject]@{ State = ${st}; Plans = ${plans} }
}

function Show-State {
    param(${bp})
    Write-Host ''
    Write-Host '  Current PWI4 instrument bindings:' -ForegroundColor Cyan
    foreach (${p} in ${bp}.Plans) {
        ${tag} = switch (${p}.Action) {
            'already-correct'       { 'OK' }
            'would-bind'            { 'NEEDS BIND' }
            'preserved-needs-force' { 'DIFFERS (preserved)' }
            'no-device'             { 'device absent' }
            'skip-no-cfg'           { 'no cfg on this unit' }
            default                 { ${p}.Action }
        }
        Write-Host ("    {0,-13} cfg='{1,-6}'  detected='{2,-6}'  {3}" -f ${p}.Target, ${p}.Cur, ${p}.Desired, ${tag})
        Write-Host ("                  source: {0}" -f ${p}.Source) -ForegroundColor DarkGray
    }
    Write-Host ('    Mount: PWI4 USB auto-detect (not bound here).  FCU/Standa: MAST_unit libximc auto (not bound here).') -ForegroundColor DarkGray
    if (${bp}.State.Pwi4Running) { Write-Host '    PWI4: RUNNING -- close it before applying changes.' -ForegroundColor Yellow }
    else { Write-Host '    PWI4: closed.' -ForegroundColor Green }
}

function Show-Diff {
    param(${bp})
    ${w} = @(${bp}.Plans | Where-Object { $_.WillWrite })
    ${pres} = @(${bp}.Plans | Where-Object { $_.Action -eq 'preserved-needs-force' })
    if (${w}.Count -eq 0 -and ${pres}.Count -eq 0) { Write-Host '  No changes needed (all bindings already correct or no devices).' -ForegroundColor Green; return }
    if (${w}.Count -gt 0) {
        Write-Host '  Changes to apply:' -ForegroundColor Cyan
        foreach (${p} in ${w}) { Write-Host ("    {0}: {1}  =>  {2}   ({3}; {4})" -f ${p}.Target, $(if (${p}.Cur) { "'" + ${p}.Cur + "'" } else { '(empty)' }), ${p}.Desired, ${p}.Reason, ${p}.CfgFile) -ForegroundColor White }
    }
    foreach (${p} in ${pres}) {
        Write-Host ("    {0}: current '{1}' is a PRESENT port differing from detected '{2}' -- PRESERVED (use Force to rebind)." -f ${p}.Target, ${p}.Cur, ${p}.Desired) -ForegroundColor Yellow
    }
}

function Apply-Plan {
    param(${bp})
    ${changed} = 0
    foreach (${p} in @(${bp}.Plans | Where-Object { $_.WillWrite })) {
        Set-CfgField -Path ${p}.Path -Field 'SerialPort' -Value ${p}.Desired
        Log ("{0}: SET SerialPort={1} ({2}; {3})" -f ${p}.Target, ${p}.Desired, ${p}.Reason, ${p}.Source)
        Write-Host ("    SET {0}: SerialPort={1}" -f ${p}.Target, ${p}.Desired) -ForegroundColor Green
        ${changed}++
    }
    if (${changed} -gt 0) {
        New-Item -ItemType Directory -Path ${StampDir} -Force | Out-Null
        ${fp} = ((${bp}.State.Devices | Sort-Object DeviceID | ForEach-Object { $_.DeviceID }) -join ';')
        Set-Content -LiteralPath (Join-Path ${StampDir} '.calibrated') -Encoding UTF8 -Value @(("calibrated {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')), ("device-fingerprint: {0}" -f ${fp}))
    }
    Write-Host ("  Done. {0} binding(s) written. Left untouched: mount, FCU, focuser calibration, pointing model, mount tuning." -f ${changed}) -ForegroundColor Cyan
    return ${changed}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] calibrate-instruments.ps1 started (Interactive={1}, DryRun={2}, Force={3})" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), [bool]${Interactive}, [bool]${DryRun}, [bool]${Force})

if (-not (Test-Path -LiteralPath ${Pwi4Settings})) {
    Write-Host ("PWI4 Settings dir not found: {0} (has the unit been provisioned + first-logon applied?)" -f ${Pwi4Settings}) -ForegroundColor Red
    Log ("PWI4 Settings dir not found: {0}" -f ${Pwi4Settings}) 'ERROR'
    if (${Interactive}) { Read-Host 'Press Enter to exit' }
    exit 2
}

# ----------------------------- INTERACTIVE --------------------------------
if (${Interactive}) {
    ${useForce} = $false
    while ($true) {
        ${bp} = Build-Plan -DoForce ${useForce}
        try { Clear-Host } catch { }
        Write-Host '==================================================' -ForegroundColor Cyan
        Write-Host '        MAST Instrument Calibration' -ForegroundColor Cyan
        Write-Host '==================================================' -ForegroundColor Cyan
        Show-State -bp ${bp}
        Write-Host ''
        Write-Host '  [V] View / refresh state'
        Write-Host '  [D] Dry run  (show the diff, write nothing)'
        Write-Host '  [A] Apply    (preservation-safe; requires PWI4 closed)'
        Write-Host '  [F] Force rewrite (rebind even present-but-different ports)'
        Write-Host '  [Q] Quit'
        ${choice} = (Read-Host 'Select').Trim().ToUpper()
        switch (${choice}) {
            'V' { ${useForce} = $false; continue }
            'D' {
                ${bpd} = Build-Plan -DoForce $false
                Write-Host ''; Show-Diff -bp ${bpd}
                Read-Host 'Press Enter to continue' | Out-Null
            }
            { $_ -eq 'A' -or $_ -eq 'F' } {
                ${doForce} = (${choice} -eq 'F')
                ${bpa} = Build-Plan -DoForce ${doForce}
                Write-Host ''
                Show-Diff -bp ${bpa}
                ${toWrite} = @(${bpa}.Plans | Where-Object { $_.WillWrite })
                if (${toWrite}.Count -eq 0) { Read-Host 'Nothing to apply. Press Enter' | Out-Null; continue }
                if (${bpa}.State.Pwi4Running) {
                    Write-Host ''
                    Write-Host '  PWI4 is RUNNING. Close PWI4 completely first (it rewrites its .cfg on exit),' -ForegroundColor Yellow
                    Write-Host '  then choose Apply again.' -ForegroundColor Yellow
                    Read-Host 'Press Enter' | Out-Null; continue
                }
                ${ans} = (Read-Host ("Apply the above {0} change(s)? [y/N]" -f ${toWrite}.Count)).Trim().ToUpper()
                if (${ans} -eq 'Y') { Write-Host ''; Apply-Plan -bp ${bpa} | Out-Null }
                else { Write-Host '  Cancelled.' -ForegroundColor DarkGray }
                Read-Host 'Press Enter' | Out-Null
            }
            'Q' { Write-Host 'Bye.'; break }
            default { }
        }
    }
    exit 0
}

# ------------------------------- CLI --------------------------------------
${bp} = Build-Plan -DoForce ([bool]${Force})
foreach (${p} in ${bp}.Plans) { Log ("{0}: action={1} cur='{2}' desired='{3}' ({4})" -f ${p}.Target, ${p}.Action, ${p}.Cur, ${p}.Desired, ${p}.Source) }
Show-State -bp ${bp}
Write-Host ''
Show-Diff -bp ${bp}

if (${DryRun}) {
    Write-Host ''
    Write-Host '  (DRY RUN - nothing written)' -ForegroundColor Cyan
    exit 0
}
${toWrite} = @(${bp}.Plans | Where-Object { $_.WillWrite })
if (${toWrite}.Count -eq 0) { exit 0 }
if (${bp}.State.Pwi4Running) {
    Write-Host ''
    Write-Host '  PWI4 is running. Close it first (it rewrites its .cfg on exit), then re-run. (Use -DryRun to inspect without closing.)' -ForegroundColor Red
    Log 'refused: PWI4 running' 'ERROR'
    exit 2
}
Write-Host ''
Apply-Plan -bp ${bp} | Out-Null
exit 0
