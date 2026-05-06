#Requires -RunAsAdministrator
<#
.SYNOPSIS
    One-time bootstrap for a freshly installed MAST IoT unit (physical or VM).

.DESCRIPTION
    Run this script ONCE on a unit that has a clean Windows IoT install with no
    answer file. It brings the machine to a state where prepare-mast-client.ps1
    can run remotely over WinRM to finish the full unit preparation.

    What this script does:
      1. Creates the 'mast' local administrator account (password: physics)
      2. Suppresses Windows Update automatic installs and reboots
      3. Enables WinRM over HTTP (port 5985) with Basic auth
      4. Opens the WinRM firewall port

    prepare-mast-client.ps1 (run remotely after this) handles:
      - Computer rename
      - WinRM HTTPS listener + self-signed cert
      - TrustedHosts configuration

    Delivery:
      - USB drive: copy to USB, open admin PowerShell on the unit, run it
      - Local keyboard / paste into an admin PowerShell session

    For VM builds using run-prov-test.py --build-image, equivalent commands are
    injected automatically into the answer file's FirstLogonCommands — no manual
    step required.
#>

param(
    [string]$MastUser     = 'mast',
    [string]$MastPassword = 'physics'
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "--- $msg" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# 1. mast local administrator account
# ---------------------------------------------------------------------------
Write-Step "Ensuring local admin account '$MastUser'"

$existing = Get-LocalUser -Name $MastUser -ErrorAction SilentlyContinue
$secPwd = ConvertTo-SecureString $MastPassword -AsPlainText -Force

if ($existing) {
    Set-LocalUser -Name $MastUser -Password $secPwd -PasswordNeverExpires $true
    Write-Host "  Account '$MastUser' already exists — password updated."
} else {
    New-LocalUser -Name $MastUser -Password $secPwd `
        -FullName 'MAST Administrator' -PasswordNeverExpires `
        -UserMayNotChangePassword | Out-Null
    Write-Host "  Account '$MastUser' created."
}

# Add to Administrators group if not already a member
$admins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "\\$MastUser$" }
if (-not $admins) {
    Add-LocalGroupMember -Group 'Administrators' -Member $MastUser
    Write-Host "  Added '$MastUser' to Administrators."
} else {
    Write-Host "  '$MastUser' is already an Administrator."
}

# ---------------------------------------------------------------------------
# 2. Suppress Windows Update automatic installs
# ---------------------------------------------------------------------------
Write-Step "Suppressing Windows Update automatic installs"

$auPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $auPath -Force | Out-Null
# AUOptions = 1: never check (fully suppressed during provisioning)
Set-ItemProperty -Path $auPath -Name NoAutoUpdate  -Value 1 -Type DWord
Set-ItemProperty -Path $auPath -Name AUOptions     -Value 1 -Type DWord
# Prevent automatic reboots even if updates somehow slip through
Set-ItemProperty -Path $auPath -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord

Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Set-Service  wuauserv -StartupType Disabled
Write-Host "  Windows Update disabled (AUOptions=1, service=Disabled)."

# ---------------------------------------------------------------------------
# 3. Enable WinRM (HTTP, Basic auth, unencrypted)
# ---------------------------------------------------------------------------
Write-Step "Enabling WinRM"

# Enable-PSRemoting starts the WinRM service and creates a default HTTP listener
Enable-PSRemoting -Force -SkipNetworkProfileCheck

# Basic auth required by pywinrm / run-prov-test.py
winrm set winrm/config/service/auth '@{Basic="true"}'

# Unencrypted HTTP — bootstrap only; prepare-mast-client.ps1 adds HTTPS
winrm set winrm/config/service '@{AllowUnencrypted="true"}'

Set-Service WinRM -StartupType Automatic
Write-Host "  WinRM enabled (HTTP, Basic auth)."

# ---------------------------------------------------------------------------
# 4. Firewall — open WinRM HTTP port
# ---------------------------------------------------------------------------
Write-Step "Opening WinRM firewall port 5985"

$ruleName = 'MAST - WinRM HTTP'
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName `
        -Direction Inbound -Protocol TCP -LocalPort 5985 `
        -Action Allow -Profile Any | Out-Null
    Write-Host "  Firewall rule '$ruleName' created."
} else {
    Write-Host "  Firewall rule '$ruleName' already exists."
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
$ip = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notmatch '^127\.' } |
    Select-Object -First 1).IPAddress

Write-Host ""
Write-Host "Bootstrap complete." -ForegroundColor Green
Write-Host ""
Write-Host "  Unit IP    : $ip"
Write-Host "  WinRM port : 5985 (HTTP)"
Write-Host "  Account    : $MastUser / $MastPassword"
Write-Host ""
Write-Host "Next: run prepare-mast-client.ps1 remotely to finish setup."
Write-Host "  From Mac:"
Write-Host "    python run-prov-test.py --host-prov <prov-ip> --host-unit $ip --hostname mast01 ..."
Write-Host "  From provisioning server (PowerShell):"
Write-Host "    `$cred = Get-Credential  # mast / physics"
Write-Host "    Invoke-Command -ComputerName $ip -Credential `$cred -FilePath .\prepare-mast-client.ps1 -ArgumentList @{HostName='mast01'}"
