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
    injected automatically into the answer file's FirstLogonCommands -- no manual
    step required.
#>

param(
    [string]$MastUser     = 'mast',
    [string]$MastPassword = 'physics',
    [string]$UnitIP       = '192.168.56.20',
    [int]   $PrefixLength = 24,
    [string]$ProvServerIP = '192.168.56.1'
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "--- $msg" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# 0. Pin the host-only NIC to a static address so the prov server can find us
#    Identification: pick the connected Ethernet adapter that does NOT carry
#    the default route (the NAT adapter does). Skipped on physical units that
#    are already on a managed LAN with a single NIC + default gateway.
# ---------------------------------------------------------------------------
Write-Step "Configuring static IP $UnitIP/$PrefixLength on host-only NIC"

$candidateAdapters = Get-NetAdapter -Physical |
    Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' }

$hostOnlyAdapter = $null
foreach ($a in $candidateAdapters) {
    $defaultRoute = Get-NetRoute -InterfaceIndex $a.ifIndex `
        -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
    if (-not $defaultRoute) { $hostOnlyAdapter = $a; break }
}

if (-not $hostOnlyAdapter) {
    Write-Host "  No gateway-less Ethernet adapter found - skipping static IP"
    Write-Host "  (single-NIC physical unit; using existing DHCP/static config)."
} else {
    $ifIdx = $hostOnlyAdapter.ifIndex
    Write-Host "  Selected adapter: $($hostOnlyAdapter.Name) (ifIndex=$ifIdx, MAC=$($hostOnlyAdapter.MacAddress))"

    Get-NetIPAddress -InterfaceIndex $ifIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    Set-NetIPInterface -InterfaceIndex $ifIdx -Dhcp Disabled -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceIndex $ifIdx -Confirm:$false -ErrorAction SilentlyContinue

    New-NetIPAddress -InterfaceIndex $ifIdx -IPAddress $UnitIP `
        -PrefixLength $PrefixLength -ErrorAction Stop | Out-Null

    Write-Host "  Set $UnitIP/$PrefixLength (no default gateway - NAT adapter keeps Internet route)."
}

# ---------------------------------------------------------------------------
# 1. mast local administrator account
# ---------------------------------------------------------------------------
Write-Step "Ensuring local admin account '$MastUser'"

$existing = Get-LocalUser -Name $MastUser -ErrorAction SilentlyContinue
$secPwd = ConvertTo-SecureString $MastPassword -AsPlainText -Force

if ($existing) {
    Set-LocalUser -Name $MastUser -Password $secPwd -PasswordNeverExpires $true
    Write-Host "  Account '$MastUser' already exists -- password updated."
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

# Flip every connection profile from Public to Private. WSMan refuses to
# enable AllowUnencrypted while any profile is Public. Safe on a dev unit;
# physical units behind a managed LAN should already be Private/Domain.
Write-Host "  Forcing all NetConnectionProfiles to Private"
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# Enable-PSRemoting starts the WinRM service and creates a default HTTP listener
Enable-PSRemoting -Force -SkipNetworkProfileCheck

# NOTE: 'winrm set ... @{Key="val"}' is unreliable from PowerShell because
# PS parses @{...} as a hashtable literal; use the WSMan: provider instead.
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true -Force            # Basic auth for pywinrm / run-prov-test.py
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true -Force      # bootstrap only; prepare-mast-client.ps1 adds HTTPS

Set-Service WinRM -StartupType Automatic
Write-Host "  WinRM enabled (HTTP, Basic auth, AllowUnencrypted=true)."

# ---------------------------------------------------------------------------
# 3b. Allow remote admin auth via local accounts (UAC token-filter bypass)
#     Without this, WinRM Basic auth with a local admin (other than the
#     built-in 'Administrator') returns 401 even when the password is right.
# ---------------------------------------------------------------------------
Write-Step "Setting LocalAccountTokenFilterPolicy=1"
$polPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
New-ItemProperty -Path $polPath -Name LocalAccountTokenFilterPolicy `
    -Value 1 -PropertyType DWord -Force | Out-Null
Restart-Service WinRM
Write-Host "  LocalAccountTokenFilterPolicy=1; WinRM restarted."

# ---------------------------------------------------------------------------
# 4. Firewall -- open WinRM HTTP port
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
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
    Select-Object -First 1).IPAddress

Write-Host ""
Write-Host "Bootstrap complete." -ForegroundColor Green
Write-Host ""
Write-Host "  Unit IP    : $ip"
Write-Host "  WinRM port : 5985 (HTTP)"
Write-Host "  Account    : $MastUser / $MastPassword"
Write-Host ""
Write-Host "Next: from the prov server ($ProvServerIP), run prepare-mast-client.ps1 remotely:"
Write-Host "    `$cred = Get-Credential  # mast / physics"
Write-Host "    Invoke-Command -ComputerName $UnitIP -Credential `$cred -FilePath .\prepare-mast-client.ps1 -ArgumentList @{HostName='mast01'}"
