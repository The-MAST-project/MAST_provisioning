#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$TaskName = 'mast-no-windows-updates'
)

# Verify the Windows Update lockdown: the enforcement task is registered and the GP
# NoAutoUpdate knob is set. wuauserv's StartMode is reported but NOT failed on -- the
# OS (WaaSMedicSvc) can re-enable it between the daily runs; the durable guarantees
# are the policy key + the recurring task.
$ErrorActionPreference = 'Stop'
$mastLogDot = Join-Path $PSScriptRoot 'mast-log.ps1'
if (-not (Test-Path $mastLogDot)) { $mastLogDot = Join-Path $PSScriptRoot '..\..\lib\mast-log.ps1' }
. $mastLogDot
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts probe optional properties
$verifyLog = Get-MastVerifyLog -Module 'windows-update-lockdown'

function W { param([string]$Line) Add-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Line) }
Set-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] verify-windows-update-lockdown.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$fail = @()

# 1) Scheduled task registered.
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) { W ("scheduled task present: {0} (state={1})" -f $TaskName, $task.State) }
else { $fail += "scheduled task '$TaskName' not registered" }

# 2) GP NoAutoUpdate set.
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$noAuto = (Get-ItemProperty -Path $au -Name 'NoAutoUpdate' -ErrorAction SilentlyContinue).NoAutoUpdate
W ("NoAutoUpdate = {0} (expect 1)" -f $noAuto)
if ($noAuto -ne 1) { $fail += "NoAutoUpdate policy not set to 1 (got '$noAuto')" }

# 3) wuauserv state -- informational only (self-heal can flip it between daily runs).
$mode = (Get-CimInstance -ClassName Win32_Service -Filter "Name='wuauserv'" -ErrorAction SilentlyContinue).StartMode
$wu = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
W ("wuauserv StartMode={0} Status={1} (informational; re-asserted daily)" -f $mode, $(if ($wu) { $wu.Status } else { 'absent' }))

if ($fail.Count -eq 0) {
    W 'PASS enforcement task registered and NoAutoUpdate policy set'
    Write-MastSmokeOk -Module 'windows-update-lockdown' | Out-Null
    exit 0
}

W ('FAIL ' + ($fail -join '; '))
exit 1
