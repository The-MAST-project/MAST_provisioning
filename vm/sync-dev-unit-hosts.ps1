#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
  Register a dev VirtualBox unit hostname on THIS machine (hosts file), simulating internal DNS.

.DESCRIPTION
  Production units resolve by corporate DNS. On a developer PC with VirtualBox host-only DHCP,
  mast01 does not resolve until something maps hostname -> IP.

  This script discovers the guest IPv4 (Guest Additions Net/*/V4/IP, preferring the host-only
  subnet; skips VirtualBox NAT 10.0.2.x which is often Net/0), else NIC1 MAC match on the host-only
  subnet, else probe WinRM HTTP 5985 among VirtualBox-style neighbors,
  then writes a marked block into
  %SystemRoot%\System32\drivers\etc\hosts so mast01 (or another name) resolves like production.

  Must run elevated (hosts file is protected). Lab-only; do not run on the production
  provisioning server when real DNS already serves mastNN.

.PARAMETER Hostname
  Short name to register (default mast01). Same as unit-registry hostname.

.PARAMETER VmName
  VirtualBox VM name (default mast-unit).

.PARAMETER IpAddress
  Skip discovery and use this IPv4.

.PARAMETER HostOnlyPrefix
  First three octets for MAC/IP filtering (default 192.168.56).

.PARAMETER VBoxManage
  Path to VBoxManage.exe (default: Program Files\Oracle\VirtualBox).
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9-]{1,15}$')]
    [string]$Hostname = 'mast01',
    [string]$VmName = 'mast-unit',
    [string]$IpAddress = '',
    [string]$HostOnlyPrefix = '192.168.56',
    [string]$VBoxManage = ''
)

$ErrorActionPreference = 'Stop'

function Write-MastObsLine {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$ts] $Message"
}

# Ctrl+C in the console sends PipelineStoppedException - route to clean exit.
trap [System.Management.Automation.PipelineStoppedException] {
    Write-MastObsLine 'Cancelled (Ctrl+C).'
    exit 130
}

function Normalize-Mac([string]$Text) {
    if (-not $Text) { return '' }
    return (($Text -replace '[:-]', '').ToLowerInvariant())
}

function Get-VBoxManagePath {
    param([string]$Explicit)
    if ($Explicit -and (Test-Path -LiteralPath $Explicit)) { return $Explicit }
    $p = Join-Path ${env:ProgramFiles} 'Oracle\VirtualBox\VBoxManage.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    throw "VBoxManage.exe not found. Install VirtualBox or pass -VBoxManage."
}

function Get-VBoxNic1MacNormalized {
    param([string]$VBoxExe, [string]$VmName)
    $lines = & $VBoxExe showvminfo $VmName --machinereadable 2>$null
    $hit = $lines | Where-Object { $_ -match '^nic1_macaddress="' }
    if (-not $hit) { return $null }
    if ($hit -match '^nic1_macaddress="([0-9A-Fa-f]{12})"') {
        $hex = $Matches[1].ToLowerInvariant()
        $pairs = for ($i = 0; $i -lt 12; $i += 2) { $hex.Substring($i, 2) }
        return ($pairs -join '-')
    }
    return $null
}

function Get-IpFromGuestProperty {
    param(
        [string]$VBoxExe,
        [string]$VmName,
        [string]$HostOnlyPrefix = '192.168.56'
    )
    # With NAT + host-only, Guest Additions often reports NAT first (e.g. 10.0.2.15 on Net/0).
    # The hosts file on the hypervisor must point at the host-only address so WinRM/prov match production.
    $prefixBase = $HostOnlyPrefix.TrimEnd('.')
    $candidates = @()
    foreach ($idx in 0..8) {
        $prop = "/VirtualBox/GuestInfo/Net/$idx/V4/IP"
        Write-MastObsLine "Guest Additions query $prop ..."
        $out = & $VBoxExe guestproperty get $VmName $prop 2>$null
        if ($out -match 'Value:\s*(\d+\.\d+\.\d+\.\d+)') {
            $addr = $Matches[1]
            if ($addr -match '^(127\.|169\.254\.)') { continue }
            $candidates += $addr
        }
    }
    if ($candidates.Count -eq 0) {
        Write-MastObsLine "Guest Additions: no IPv4 in Net/0..Net/8 (install Guest Additions or wait after boot)."
        return $null
    }
    Write-MastObsLine ("Guest Additions raw IPv4 list: {0}" -f ($candidates -join ', '))
    $onHostOnly = @($candidates | Where-Object { $_ -like ($prefixBase + '.*') } | Select-Object -Unique)
    if ($onHostOnly.Count -ge 1) {
        if ($onHostOnly.Count -gt 1) {
            Write-Warning ("Multiple $($prefixBase).x from GA: {0}; using {1}. Pass -IpAddress to override." -f `
                    ($onHostOnly -join ', '), $onHostOnly[0])
        }
        return $onHostOnly[0]
    }
    # Default VBox NAT segment -- never use for mast01 on the host (wrong interface).
    $nonVboxNat = @($candidates | Where-Object { $_ -notmatch '^10\.0\.2\.' })
    if ($nonVboxNat.Count -eq 1) {
        Write-MastObsLine ("Guest Additions: using {0} (no {1}.x in GA props; not VBox NAT 10.0.2.*)." -f $nonVboxNat[0], $prefixBase)
        return $nonVboxNat[0]
    }
    Write-MastObsLine ("Guest Additions: no {0}.x and only NAT/other ({1}) -- falling back to ARP/WinRM discovery." -f `
            $prefixBase, ($candidates -join ', '))
    return $null
}

function Test-MastWinRmHttpOpen {
    param([string]$ComputerName, [int]$TimeoutMs = 1200, [switch]$Quiet)
    if (-not $Quiet) {
        Write-MastObsLine "Probing TCP ${ComputerName}:5985 (timeout ${TimeoutMs}ms)..."
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = $false
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($ComputerName, 5985, $null, $null)
        $wait = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $wait) {
            try { $client.Close() } catch {}
        } else {
            try {
                $client.EndConnect($iar)
                $ok = $true
            } catch {
                try { $client.Close() } catch {}
            }
            if ($ok) {
                try { $client.Close() } catch {}
            }
        }
    } catch {
    } finally {
        $sw.Stop()
        if (-not $Quiet) {
            $label = if ($ok) { 'open' } else { 'closed or timeout' }
            Write-MastObsLine ("Port 5985 on {0}: {1} ({2}ms)" -f $ComputerName, $label, [int]$sw.ElapsedMilliseconds)
        }
    }
    return $ok
}

function Get-IpFromNeighborMac {
    param([string]$MacDash, [string]$Prefix)
    $want = Normalize-Mac $MacDash
    if (-not $want) { return $null }
    $neighbors = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
            $_.IPAddress -like ($Prefix + '.*') -and $_.LinkLayerAddress
        })
    foreach ($n in $neighbors) {
        if ((Normalize-Mac $n.LinkLayerAddress) -eq $want) {
            return $n.IPAddress
        }
    }
    return $null
}

function Get-IpVBoxNeighborsDisambiguate {
    param([string]$Prefix)
    $neighbors = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
            $_.IPAddress -like ($Prefix + '.*') -and $_.LinkLayerAddress -and
            ((Normalize-Mac $_.LinkLayerAddress).StartsWith('080027'))
        })
    $ips = @($neighbors | Select-Object -ExpandProperty IPAddress -Unique | Sort-Object)
    if ($ips.Count -eq 0) { return $null }
    if ($ips.Count -eq 1) {
        Write-MastObsLine "Discovery: single VirtualBox-style neighbor on ${Prefix}.x -> $($ips[0])"
        return $ips[0]
    }
    $worst = [math]::Ceiling($ips.Count * 1.3)
    Write-MastObsLine ("Discovery: {0} VirtualBox neighbor(s) on {1}.x; TCP 5985 probes next (~{2:N0}s worst case)." -f `
            $ips.Count, $Prefix, $worst)
    $open = @()
    foreach ($a in $ips) {
        if (Test-MastWinRmHttpOpen -ComputerName $a) {
            $open += $a
        }
    }
    if ($open.Count -eq 1) {
        Write-MastObsLine "Discovery: WinRM HTTP open -> $($open[0])"
        return $open[0]
    }
    if ($open.Count -gt 1) {
        $msg = "Multiple IPs respond on WinRM (5985): {0}. Using {1}; pass -IpAddress if wrong." -f `
            ($open -join ', '), $open[0]
        Write-Warning $msg
        return $open[0]
    }
    Write-Warning "No VirtualBox neighbor on ${Prefix}.x had WinRM port 5985 open (is bootstrap finished?)."
    Write-MastObsLine ("Candidates were: {0} -- try: .\tools\sync-dev-unit-hosts.ps1 -IpAddress <addr>" -f ($ips -join ', '))
    return $null
}

function Update-HostsMarkedBlock {
    param(
        [string]$HostsPath,
        [string]$Hostname,
        [string]$Ip
    )
    $begin = "# <MAST-DEV-DNS hostname=`"$Hostname`">"
    $end = "# </MAST-DEV-DNS hostname=`"$Hostname`">"
    $lines = @()
    if (Test-Path -LiteralPath $HostsPath) {
        $lines = @(Get-Content -LiteralPath $HostsPath -ErrorAction Stop)
    }
    $be = [regex]::Escape($begin)
    $ee = [regex]::Escape($end)
    $pattern = "(?ms)^\s*$be\s*\r?\n.*?^\s*$ee\s*\r?\n?"
    $blob = ($lines -join "`r`n")
    $blob = [regex]::Replace($blob, $pattern, '')
    $blob = $blob.TrimEnd()
    $insert = "${begin}`r`n${Ip}`t${Hostname}`r`n${end}`r`n"
    if ($blob.Length -gt 0 -and -not $blob.EndsWith("`n")) {
        $blob += "`r`n"
    }
    $blob += $insert
    $backup = "${HostsPath}.mast-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    if (Test-Path -LiteralPath $HostsPath) {
        Copy-Item -LiteralPath $HostsPath -Destination $backup -Force
        Write-MastObsLine "Backup: $backup"
    }
    # hosts is often ReadOnly + System; Set-Content can fail with "Stream was not readable".
    $hi = Get-Item -LiteralPath $HostsPath -Force -ErrorAction SilentlyContinue
    if ($hi -and $hi.IsReadOnly) {
        $hi.IsReadOnly = $false
    }
    Write-MastObsLine "Writing hosts file (merge marked block)..."
    [System.IO.File]::WriteAllText($HostsPath, $blob, [System.Text.Encoding]::ASCII)
    Write-MastObsLine "Updated hosts: $Hostname -> $Ip"
}

# --- main ---
$syncStart = Get-Date
Write-MastObsLine "sync-dev-unit-hosts starting (Hostname=$Hostname VmName=$VmName)..."
$VBoxExe = Get-VBoxManagePath $VBoxManage
$ip = $IpAddress

if ($ip) {
    Write-MastObsLine "Using -IpAddress $ip (skipping discovery)."
}

if (-not $ip) {
    $ip = Get-IpFromGuestProperty -VBoxExe $VBoxExe -VmName $VmName -HostOnlyPrefix $HostOnlyPrefix
    if ($ip) { Write-MastObsLine "Discovery: Guest Additions IPv4 = $ip" }
}

if (-not $ip) {
    Write-MastObsLine "Discovery: VBox NIC1 MAC + ARP on $($HostOnlyPrefix.TrimEnd('.')).x ..."
    $mac = Get-VBoxNic1MacNormalized -VBoxExe $VBoxExe -VmName $VmName
    if ($mac) {
        Write-MastObsLine "NIC1 MAC = $mac"
        $ip = Get-IpFromNeighborMac -MacDash $mac -Prefix $HostOnlyPrefix.TrimEnd('.')
        if ($ip) { Write-MastObsLine "Neighbor IP = $ip (MAC match)" }
    } else {
        Write-MastObsLine "Could not read NIC1 MAC from showvminfo (VM name wrong?)."
    }
}

if (-not $ip) {
    Write-MastObsLine "Discovery: enumerate VirtualBox neighbors + WinRM ..."
    $ip = Get-IpVBoxNeighborsDisambiguate -Prefix $HostOnlyPrefix.TrimEnd('.')
}

if (-not $ip) {
    throw "Could not determine unit IP. Power on the VM, wait for bootstrap (WinRM on 5985), then retry or pass -IpAddress explicitly."
}

$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
Update-HostsMarkedBlock -HostsPath $hostsPath -Hostname $Hostname -Ip $ip

try {
    Write-MastObsLine "Verify: DNS lookup for '$Hostname' ..."
    $chk = [System.Net.Dns]::GetHostAddresses($Hostname) |
        Where-Object AddressFamily -EQ ([System.Net.Sockets.AddressFamily]::InterNetwork) |
        Select-Object -First 1
    if ($chk) {
        Write-MastObsLine "Verify OK: GetHostAddresses('$Hostname') -> $($chk.IPAddressToString)"
    }
} catch {
    Write-MastObsLine "WARN: post-write DNS check failed: $($_.Exception.Message)"
}

$dur = (Get-Date) - $syncStart
Write-MastObsLine ("sync-dev-unit-hosts finished in {0:N1}s" -f $dur.TotalSeconds)
