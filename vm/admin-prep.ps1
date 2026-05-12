#Requires -RunAsAdministrator
<#
.SYNOPSIS
  One-time elevated host preparation for the Windows 11 provisioning server.

.DESCRIPTION
  Stage A items from the plan that require Administrator privileges:
    1. Add VirtualBox + Python 3.12 to the *Machine* PATH so every shell sees them.
    2. Add an inbound firewall rule allowing ICMP from 192.168.56.0/24 (host-only
       net) for ping reachability checks during provisioning.

  Idempotent -- safe to re-run.

  Non-admin items (already handled by run-prov-test.py / build scripts):
    - Python install (winget)
    - pip install pywinrm
    - vault/ directory creation
    - User-scope PATH (already set during initial bring-up)
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Write-Headline($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# ---------------------------------------------------------------------------
# 1. Machine PATH (so SYSTEM-context Task Scheduler jobs see the binaries too)
# ---------------------------------------------------------------------------
Write-Headline "Adding VirtualBox + Python 3.12 to Machine PATH"

$paths = @(
    'C:\Program Files\Oracle\VirtualBox',
    'C:\Program Files\Python312',
    'C:\Program Files\Python312\Scripts'
)
$machinePath = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name PATH).PATH
$parts = ($machinePath -split ';') | Where-Object { $_ }
$changed = $false
foreach ($p in $paths) {
    if (-not (Test-Path $p)) {
        Write-Warning "  Skipping (not found): $p"
        continue
    }
    if ($parts -notcontains $p) {
        $parts += $p
        $changed = $true
        Write-Host "  + $p"
    } else {
        Write-Host "  = $p"
    }
}
if ($changed) {
    [System.Environment]::SetEnvironmentVariable('PATH', ($parts -join ';'), 'Machine')
    Write-Host "Machine PATH updated. Restart shells to pick up the change."
} else {
    Write-Host "Machine PATH unchanged."
}

# ---------------------------------------------------------------------------
# 2. Firewall -- ICMP inbound from host-only subnet
# ---------------------------------------------------------------------------
Write-Headline "Allowing inbound ICMP from 192.168.56.0/24"

$ruleName = 'MAST host-only ICMP'
$existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "  Rule '$ruleName' already exists."
} else {
    New-NetFirewallRule -DisplayName $ruleName `
        -Direction Inbound -Protocol ICMPv4 -IcmpType 8 `
        -RemoteAddress 192.168.56.0/24 `
        -Action Allow -Profile Any | Out-Null
    Write-Host "  Created firewall rule: $ruleName"
}

Write-Host "`nHost prep complete." -ForegroundColor Green
