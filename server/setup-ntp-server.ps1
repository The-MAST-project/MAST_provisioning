#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  One-time elevated setup: make this provisioning server an authoritative NTP server.

.DESCRIPTION
  MAST units frequently cannot reach public NTP (UDP 123 blocked, or the unit is
  on an isolated / link-local network with no internet route). A wrong clock then
  breaks TLS certificate validation, so the unit's HTTPS git clone during
  provisioning fails with confusing cert errors -- and a large clock skew also
  destabilizes long-running WinRM (WS-Management) sessions.

  Fix: the provisioning server (which does have correct time and is always
  reachable by the units it provisions) serves NTP. The units sync from it via
  the early 'timesync' provider (server/providers/timesync), which discovers this
  server from the active SMB connection and peers w32time at it.

  This script enables the W32Time NTP server, announces it as a reliable source
  (required on a non-domain standalone box), and opens inbound UDP 123. It is
  idempotent -- safe to re-run. Run it once as part of provisioning-server setup
  (see docs/provisioning-server-setup.md), same as setup-smb-share.ps1.

.PARAMETER Port
  NTP UDP port to open inbound. Default 123 (the standard).

.EXAMPLE
  # Elevated PowerShell on the provisioning server:
  .\server\setup-ntp-server.ps1
#>

[CmdletBinding()]
param(
    [int]$Port = 123
)

$ErrorActionPreference = 'Stop'

Write-Host "Configuring this host as a MAST NTP server (W32Time)..."

# 1. Enable the NTP server provider.
$ntpKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer'
Set-ItemProperty -Path $ntpKey -Name 'Enabled' -Value 1 -Type DWord
Write-Host "  NtpServer provider enabled."

# 2. Announce as a reliable time source. On a non-domain standalone box w32time
#    will otherwise refuse to serve (it considers itself unsynchronized). 5 =
#    0x1 (always announce) | 0x4 (announce reliable). This lets the server hand
#    out its own (correct) clock without needing an upstream NTP peer.
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config' -Name 'AnnounceFlags' -Value 5 -Type DWord
Write-Host "  AnnounceFlags=5 (reliable time source)."

# 3. Apply config + ensure the service is running and auto-start.
& w32tm.exe /config /update | Out-Null
Set-Service -Name w32time -StartupType Automatic
Restart-Service -Name w32time
Write-Host "  w32time restarted (StartupType=Automatic)."

# 4. Firewall: allow inbound NTP (UDP 123).
$ruleName = 'MAST - NTP Server (UDP 123)'
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
        -Protocol UDP -LocalPort $Port -Profile Any | Out-Null
    Write-Host "  Firewall rule created: $ruleName"
} else {
    Write-Host "  Firewall rule already present: $ruleName"
}

# 5. Verify + show how units should peer this server.
Start-Sleep -Seconds 1
Write-Host ""
Write-Host "=== w32tm /query /configuration (NtpServer section) ==="
(& w32tm.exe /query /configuration) | Select-String -Pattern 'NtpServer|Enabled|AnnounceFlags' | ForEach-Object { Write-Host ("  " + $_.Line.Trim()) }
Write-Host "=== w32tm /query /status ==="
& w32tm.exe /query /status

$ips = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne '127.0.0.1' } | Select-Object -ExpandProperty IPAddress) -join ', '
Write-Host ""
Write-Host "NTP server ready. This host's IPv4 addresses: $ips"
Write-Host "Units peer it with: w32tm /config /manualpeerlist:'<thisServerIP>,0x8' /syncfromflags:manual /update ; w32tm /resync /force"
Write-Host "(The 'timesync' provider does this automatically, discovering the server from the SMB connection.)"
exit 0
