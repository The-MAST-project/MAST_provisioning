#Requires -Version 5.1
<#
.SYNOPSIS
  Delete the dev VirtualBox unit VM, rebuild the autounattend ISO, recreate the VM, and start install.

.DESCRIPTION
  End-to-end helper for a clean factory-simulation run:
    1. Optionally rebuild autounattend-mast.iso (factory user, OEM hostname; bootstrap-winrm.cmd + .ps1 staged on ISO, not auto-run).
    2. Power off and unregister the existing VM (deletes disks).
    3. Run vbox-create-unit.ps1 with the Windows ISO and autounattend ISO.
    4. Start the VM (default: GUI so you can watch). If EFI shows
       "Press any key to boot from CD or DVD...", click the VM window and press Enter once.
  5. By default exit after starting the VM. With -WaitForDevWinRm, poll until WinRM HTTP (port 5985)
     answers (run bootstrap-winrm.cmd in the guest first). Tries -BootstrapWinRmHost first (hostname);
     if unset or unreachable, scans the host-only subnet prefix (DHCP; dev VMs).

.PARAMETER WaitForDevWinRm
  After starting the VM, wait until TCP port 5985 is open on the guest (max
  -BootstrapTimeoutMinutes). Use only after you ran bootstrap-winrm.cmd in the VM
  and want an automated smoke check. Default: do not wait.

.PARAMETER BootstrapWinRmHost
  Optional hostname to probe first (must resolve via DNS/hosts, e.g. mast01). Units use DHCP;
  identity is hostname - use DNS on the host or omit and rely on subnet scan.

.PARAMETER HostOnlyDhcpScanPrefix
  First three octets for dev VM discovery when BootstrapWinRmHost does not answer (default
  192.168.56). Set empty to disable scanning.

.PARAMETER BootstrapTimeoutMinutes
  Max time to wait for WinRM (default 120).

.PARAMETER BootstrapPollSeconds
  Seconds between connection attempts (default 30).

.PARAMETER IsoPath
  Path to the Windows 11 / IoT LTSC install ISO (required).

.PARAMETER AutounattendIso
  Path to the autounattend ISO. Default: <repo>\autounattend-mast.iso

.PARAMETER VmName
  VirtualBox VM name. Default: mast-unit

.PARAMETER SkipRebuildAutounattend
  Do not run build-autounattend-iso.ps1; use the existing AutounattendIso file as-is.

.PARAMETER StartVmType
  VirtualBox session type: gui (default) or headless.

.PARAMETER DiskSizeGb, MemoryMb, Cpus
  Passed through to vbox-create-unit.ps1.

.EXAMPLE
  .\vbox-recreate-unit.ps1 -IsoPath C:\ISOs\Win11_IoT_LTSC.iso

.EXAMPLE
  # After Windows installs, log in, run bootstrap from D:\, then optionally wait for WinRM:
  .\vbox-recreate-unit.ps1 -IsoPath C:\ISOs\Win11_IoT_LTSC.iso -WaitForDevWinRm
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IsoPath,

    [string]$AutounattendIso = '',
    [string]$VmName = 'mast-unit',
    [switch]$SkipRebuildAutounattend,
    [ValidateSet('gui', 'headless')]
    [string]$StartVmType = 'gui',
    [int]$DiskSizeGb = 80,
    [int]$MemoryMb = 8192,
    [int]$Cpus = 4,

    [switch]$WaitForDevWinRm,
    [string]$BootstrapWinRmHost = '',
    [string]$HostOnlyDhcpScanPrefix = '192.168.56',
    [ValidateRange(1, 1440)]
    [int]$BootstrapTimeoutMinutes = 120,
    [ValidateRange(5, 600)]
    [int]$BootstrapPollSeconds = 30
)

$ErrorActionPreference = 'Stop'
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

$totalSw = [System.Diagnostics.Stopwatch]::StartNew()
$phaseSw = [System.Diagnostics.Stopwatch]::StartNew()
function Format-MastElapsed([TimeSpan]$t) {
    if ($t.TotalHours -ge 1) { return $t.ToString('h\:mm\:ss') }
    if ($t.TotalMinutes -ge 1) { return ('{0:N1} min' -f $t.TotalMinutes) }
    return ('{0:N2}s' -f $t.TotalSeconds)
}
function Write-MastTiming([string]$Label) {
    $phaseSw.Stop()
    Write-Host ('[TIMING] {0}: {1}' -f $Label, (Format-MastElapsed $phaseSw.Elapsed)) -ForegroundColor DarkCyan
    $phaseSw.Restart()
}
function Write-MastTimingTotal([string]$ScriptName) {
    $totalSw.Stop()
    Write-Host ('[TIMING] Total ({0}): {1}' -f $ScriptName, (Format-MastElapsed $totalSw.Elapsed)) -ForegroundColor Cyan
}

$VBoxManage = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
if (-not (Test-Path $VBoxManage)) {
    throw "VBoxManage not found at $VBoxManage"
}

function VBox { & $VBoxManage @args }

function Test-MastTcpPortOpen {
    param([string]$ComputerName, [int]$Port = 5985, [int]$TimeoutMs = 150)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($iar)
        return $client.Connected
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch {}
    }
}

if (-not (Test-Path $IsoPath)) {
    throw "Windows ISO not found: $IsoPath"
}
$IsoPath = (Resolve-Path $IsoPath).Path

if (-not $AutounattendIso) {
    $AutounattendIso = Join-Path $RepoRoot 'autounattend-mast.iso'
}

Set-Location $RepoRoot
$phaseSw.Restart()

Write-Host "`n=== Rebuild autounattend ISO ===" -ForegroundColor Cyan
if (-not $SkipRebuildAutounattend) {
    # IoT LTSC retail/VL ISOs ship multiple indexes; InstallFrom must match dism /Get-WimInfo Name.
    # KMS client setup key (Microsoft Learn): selects LTSC volume channel; omit ProductKey only if you know your media.
    & (Join-Path $RepoRoot 'build-autounattend-iso.ps1') `
        -WindowsEdition 'Windows 11 IoT Enterprise LTSC' `
        -ProductKey 'M7XTQ-FN8P6-TTKYV-9D4CC-J462D'
    $builtAu = Join-Path $RepoRoot 'autounattend-mast.iso'
    if (-not (Test-Path $builtAu)) { throw "build-autounattend-iso.ps1 did not produce $builtAu" }
    $AutounattendIso = (Resolve-Path $builtAu).Path
} else {
    if (-not (Test-Path $AutounattendIso)) {
        throw "Autounattend ISO not found: $AutounattendIso (omit -SkipRebuildAutounattend to build it)."
    }
    $AutounattendIso = (Resolve-Path $AutounattendIso).Path
    Write-Host "Skipped build-autounattend-iso.ps1; using: $AutounattendIso"
}
Write-MastTiming 'Autounattend ISO'

Write-Host "`n=== Remove existing VM '$VmName' (if any) ===" -ForegroundColor Cyan
$list = VBox list vms 2>&1 | Out-String
if ($list -match [regex]::Escape("`"$VmName`"")) {
    $info = VBox showvminfo $VmName --machinereadable 2>&1 | Out-String
    if ($info -match 'VMState="running"') {
        Write-Host "  Stopping $VmName..."
        VBox controlvm $VmName poweroff
        Start-Sleep -Seconds 4
    }
    Write-Host "  Unregistering and deleting $VmName..."
    VBox unregistervm $VmName --delete
} else {
    Write-Host "  No VM named '$VmName'."
}
Write-MastTiming 'Remove old VM'

Write-Host "`n=== Create VM ===" -ForegroundColor Cyan
$createArgs = @{
    IsoPath         = $IsoPath
    AutounattendIso = $AutounattendIso
    VmName          = $VmName
    DiskSizeGb      = $DiskSizeGb
    MemoryMb        = $MemoryMb
    Cpus            = $Cpus
}
& (Join-Path $RepoRoot 'vbox-create-unit.ps1') @createArgs
Write-MastTiming 'vbox-create-unit.ps1'

Write-Host "`n=== Start VM ($StartVmType) ===" -ForegroundColor Cyan
& $VBoxManage startvm $VmName --type $StartVmType
if ($LASTEXITCODE -ne 0) {
    throw (
        "VBoxManage startvm failed (exit $LASTEXITCODE). VM '$VmName' may already be running or locked. " +
        "Close the VM window, or run: VBoxManage controlvm '$VmName' poweroff"
    )
}
Write-Host "  If you see 'Press any key to boot from CD or DVD...', click the VM window and press Enter." -ForegroundColor Yellow
Write-MastTiming 'Start VM'

if ($WaitForDevWinRm) {
    Write-Host "`n=== Wait for WinRM :5985 (after manual bootstrap in the guest) ===" -ForegroundColor Cyan
    Write-Host "  Probing hostname first (if set), then host-only DHCP scan (dev)."
    $deadline = [datetime]::UtcNow.AddMinutes($BootstrapTimeoutMinutes)
    $winRmUp = $false
    while ([datetime]::UtcNow -lt $deadline) {
        if ($BootstrapWinRmHost -and (Test-MastTcpPortOpen -ComputerName $BootstrapWinRmHost)) {
            $winRmUp = $true
            Write-Host "  WinRM reachable via hostname $BootstrapWinRmHost." -ForegroundColor Green
            break
        }
        if ($HostOnlyDhcpScanPrefix) {
            $base = $HostOnlyDhcpScanPrefix.TrimEnd('.')
            foreach ($last in 2..254) {
                $addr = "$base.$last"
                if (Test-MastTcpPortOpen -ComputerName $addr -TimeoutMs 120) {
                    $winRmUp = $true
                    Write-Host "  WinRM port open on $addr (DHCP). Register this host in DNS under mastNN." -ForegroundColor Green
                    break
                }
            }
            if ($winRmUp) { break }
        }
        Start-Sleep -Seconds $BootstrapPollSeconds
        Write-Host ('  Still waiting... {0:N1} min elapsed (poll every {1}s, limit {2} min)' -f `
            $phaseSw.Elapsed.TotalMinutes, $BootstrapPollSeconds, $BootstrapTimeoutMinutes)
    }
    if (-not $winRmUp) {
        throw "WinRM did not become reachable within $BootstrapTimeoutMinutes minutes. Log into the VM, run D:\bootstrap-winrm.cmd -MastHostName mastNN (Run as administrator), reboot if prompted, then retry with -WaitForDevWinRm or sync hosts and test manually."
    }
    Write-MastTiming 'WinRM port open (after manual bootstrap)'

    Write-Host "`nDone. WinRM HTTP is up - run prepare-mast-client.ps1 when ready." -ForegroundColor Green
    Write-Host '  Register the guest hostname on this PC (elevated): tools\sync-dev-unit-hosts.ps1'
    Write-Host '  Then from the prov server use the same mastNN in --host and in -HostName for prepare-mast-client.'
} else {
    Write-Host "`nDone (no WinRM wait). After Windows finishes: log in, run bootstrap-winrm.cmd from the autounattend ISO (or USB) as Administrator with -MastHostName mastNN (or pass args via cmd.exe), confirm [OK], then tools\sync-dev-unit-hosts.ps1 on the host and prepare-mast-client from the prov server." -ForegroundColor Green
}

Write-Host ""
Write-MastTimingTotal 'vbox-recreate-unit.ps1'
