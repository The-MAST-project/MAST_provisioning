#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Install (or update) the Task Scheduler job that runs check-and-provision.ps1
  on the Windows provisioning host.

.DESCRIPTION
  Stage F installer. Idempotent.

  Trigger:    every 30 minutes, starting 5 minutes after registration.
  Action:     PowerShell -File <repo>\server\check-and-provision.ps1
  Identity:   SYSTEM (no logged-in user required, no stored credential)
  Conditions: not battery-only; wakes the computer to run

.PARAMETER RepoTop
  Path to the MAST_provisioning checkout on this host. Default: the
  great-grandparent of this script (so it works as
  <repo>\server\install-scheduled-task.ps1).

.PARAMETER IntervalMinutes
  How often to run. Default 30.

.PARAMETER TaskName
  Default 'MAST-CheckAndProvision'.

.PARAMETER Uninstall
  Remove the task instead of creating/updating it.
#>

[CmdletBinding()]
param(
    [string]$RepoTop         = (Split-Path -Parent (Split-Path -Parent $PSCommandPath)),
    [int]   $IntervalMinutes = 30,
    [string]$TaskName        = 'MAST-CheckAndProvision',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
    } else {
        Write-Host "Task '$TaskName' not found - nothing to do."
    }
    exit 0
}

$script = Join-Path $RepoTop 'server\check-and-provision.ps1'
if (-not (Test-Path $script)) {
    throw "check-and-provision.ps1 not found at $script"
}

$argLine = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`""
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine -WorkingDirectory $RepoTop

$trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(5)) `
            -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -WakeToRun `
            -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
            -MultipleInstances IgnoreNew

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Set-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings | Out-Null
    Write-Host "Updated scheduled task '$TaskName'." -ForegroundColor Green
} else {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description 'MAST autonomous provisioning loop. Runs check-and-provision.ps1 every N minutes.' | Out-Null
    Write-Host "Registered scheduled task '$TaskName'." -ForegroundColor Green
}

Write-Host ""
Write-Host "Run interval: $IntervalMinutes minutes"
Write-Host "Action:       powershell.exe $argLine"
Write-Host "Identity:     SYSTEM"
Write-Host ""
Write-Host "View status:  Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo"
Write-Host "Run now:      Start-ScheduledTask -TaskName $TaskName"
Write-Host "Uninstall:    .\install-scheduled-task.ps1 -Uninstall"
