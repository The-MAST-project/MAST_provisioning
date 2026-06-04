<#
.SYNOPSIS
  Create the mast-unit VirtualBox VM for the MAST provisioning dev loop.

.DESCRIPTION
  Stage B helper. Idempotent -- re-running on an existing VM is a no-op.

  What this script does (everything *automatable* about Stage B):
    1. Creates a VirtualBox VM named 'mast-unit' (Windows 11, 64-bit, EFI)
    2. Configures CPU / RAM / storage / firmware
    3. Attaches a fresh dynamic VDI as the OS disk
    4. Sets up two network adapters:
         - Adapter 1: NAT (for ISO download / activation)
         - Adapter 2: Host-only on the existing 192.168.56.1/24 network
    5. Mounts the supplied Windows install ISO

  What you do MANUALLY after this script:
    A. VBoxManage startvm mast-unit --type gui
    B. Walk through the Windows installer in the GUI window
    C. After Windows boots:
       - Leave the host-only adapter on DHCP (enable VirtualBox DHCP for the
         host-only network if needed), or use a temporary address until DNS/hosts
         maps the unit hostname (mast01) from this host.
       - Run bootstrap-winrm.cmd as Administrator (from ISO/USB; same folder as .ps1). Confirm [OK] in the summary.
         Bootstrap does all first-time prep (mast user, WinRM HTTP/5985, firewall, OpenSSH, Npcap, rename); no separate prepare step.
       - Verify WinRM reachability from this host (the prov server) on
         port 5985 using the unit hostname once it resolves
    D. Power off cleanly, then come back here and run:
         vbox-create-unit.ps1 -SnapshotOnly
       to take the 'clean-state' and 'post-prepare' snapshots.

.PARAMETER IsoPath
  Path to a Windows 11 / Windows IoT LTSC install ISO. Required unless
  -SnapshotOnly is specified.

.PARAMETER AutounattendIso
  Optional. Path to an autounattend ISO (built by build-autounattend-iso.ps1).
  When supplied, mounts the Windows install ISO on SATA port 1 (EFI must boot
  that disc) and the autounattend ISO on port 2. Setup discovers Autounattend.xml
  on the second optical volume during windowsPE. Skips the manual install
  walkthrough entirely. The autounattend ISO also carries bootstrap-winrm.cmd and
  bootstrap-winrm.ps1 at its root; after first login run bootstrap-winrm.cmd as
  Administrator before the prov server uses WinRM.

.PARAMETER VmName
  VM name in VirtualBox. Default 'mast-unit'.

.PARAMETER DiskSizeGb
  OS disk size, default 80 GB.

.PARAMETER MemoryMb
  RAM in MB, default 8192.

.PARAMETER Cpus
  vCPU count, default 4.

.PARAMETER SnapshotOnly
  Skip VM creation/configuration; only take post-install snapshots.
  Use after the manual Windows install + bootstrap step.
#>

[CmdletBinding()]
param(
    [string]$IsoPath,
    [string]$AutounattendIso,
    [string]$VmName      = 'mast-unit',
    [int]   $DiskSizeGb  = 80,
    [int]   $MemoryMb    = 8192,
    [int]   $Cpus        = 4,
    [switch]$SnapshotOnly
)

$ErrorActionPreference = 'Stop'

$VBoxManage = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
if (-not (Test-Path $VBoxManage)) {
    throw "VBoxManage not found at $VBoxManage"
}

function VBox { & $VBoxManage @args }

function Write-Headline($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

function Test-VmExists([string]$name) {
    $list = VBox list vms
    return ($list -match [regex]::Escape("`"$name`""))
}

function Test-HostOnlyNetExists {
    $nets = VBox list hostonlyifs
    return ($nets -match '192\.168\.56\.1')
}

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
function Write-MastTimingTotal([string]$Note) {
    $totalSw.Stop()
    Write-Host ('[TIMING] Total (vbox-create-unit.ps1 {0}): {1}' -f $Note, (Format-MastElapsed $totalSw.Elapsed)) -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Snapshot-only mode
# ---------------------------------------------------------------------------
if ($SnapshotOnly) {
    $phaseSw.Restart()
    Write-Headline "Snapshot-only mode for VM '$VmName'"
    if (-not (Test-VmExists $VmName)) { throw "VM '$VmName' does not exist." }

    $info = VBox showvminfo $VmName --machinereadable | Out-String
    if ($info -match 'VMState="running"') {
        throw "VM '$VmName' is running. Power it off cleanly first (shutdown from inside Windows)."
    }

    $existingSnaps = VBox snapshot $VmName list 2>&1 | Out-String
    foreach ($snap in 'clean-state','post-prepare') {
        if ($existingSnaps -match [regex]::Escape("Name: $snap")) {
            Write-Host "  Snapshot '$snap' already exists -- skipping."
        } else {
            Write-Host "  Taking snapshot '$snap'..."
            VBox snapshot $VmName take $snap --description "Auto-taken by vbox-create-unit.ps1"
        }
    }
    Write-MastTiming 'Snapshots'
    Write-Host "`nSnapshots ready. Restore with:"
    Write-Host "  VBoxManage controlvm $VmName poweroff"
    Write-Host "  VBoxManage snapshot $VmName restore post-prepare"
    Write-Host "  VBoxManage startvm $VmName --type gui"
    Write-MastTimingTotal 'SnapshotOnly'
    exit 0
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if (-not $IsoPath) {
    throw "Pass -IsoPath <path> with a Windows 11 / IoT LTSC install ISO."
}
if (-not (Test-Path $IsoPath)) {
    throw "ISO not found: $IsoPath"
}
$IsoPath = (Resolve-Path $IsoPath).Path

if ($AutounattendIso) {
    if (-not (Test-Path $AutounattendIso)) {
        throw "Autounattend ISO not found: $AutounattendIso"
    }
    $AutounattendIso = (Resolve-Path $AutounattendIso).Path
}

if (-not (Test-HostOnlyNetExists)) {
    Write-Warning "No host-only network with 192.168.56.1 found. Create one in VirtualBox > Tools > Network Manager (subnet 192.168.56.0/24). Enable the DHCP server there if you want addresses assigned automatically."
    Write-MastTimingTotal '(preflight failed)'
    exit 1
}

if (Test-VmExists $VmName) {
    Write-Host "VM '$VmName' already exists -- skipping creation steps."
    Write-Host "Delete it first if you want to recreate: VBoxManage unregistervm $VmName --delete"
    Write-MastTimingTotal '(VM already exists)'
    exit 0
}

# ---------------------------------------------------------------------------
# Create VM
# ---------------------------------------------------------------------------
$phaseSw.Restart()
Write-Headline "Creating VM '$VmName'"
VBox createvm --name $VmName --ostype Windows11_64 --register
Write-MastTiming 'Register VM'

# ---------------------------------------------------------------------------
# Hardware: CPU / RAM / firmware / clipboard / paravirt
# ---------------------------------------------------------------------------
Write-Headline "Configuring hardware ($Cpus vCPU, $MemoryMb MB, EFI, secure boot off)"
VBox modifyvm $VmName `
    --memory $MemoryMb `
    --cpus $Cpus `
    --vram 128 `
    --firmware efi `
    --rtcuseutc on `
    --graphicscontroller vboxsvga `
    --audio-driver none `
    --usb-xhci on `
    --paravirtprovider default `
    --clipboard-mode bidirectional `
    --draganddrop bidirectional

# Add TPM 2.0 (Windows 11 hard requirement)
VBox modifyvm $VmName --tpm-type 2.0
Write-MastTiming 'Hardware + TPM'

# ---------------------------------------------------------------------------
# Storage: SATA controller + dynamic VDI
# ---------------------------------------------------------------------------
Write-Headline "Creating $DiskSizeGb GB OS disk"
$vmFolder = (VBox showvminfo $VmName --machinereadable | Select-String '^CfgFile=' |
             ForEach-Object { ($_ -split '=',2)[1].Trim('"') })
$vmDir = Split-Path $vmFolder -Parent
$vdiPath = Join-Path $vmDir "$VmName.vdi"

VBox createmedium disk --filename $vdiPath --size ($DiskSizeGb * 1024) --format VDI --variant Standard

VBox storagectl $VmName --name SATA --add sata --controller IntelAhci --portcount 4 --bootable on
VBox storageattach $VmName --storagectl SATA --port 0 --device 0 --type hdd --medium $vdiPath

# ---------------------------------------------------------------------------
# Storage: ISO(s) on SATA (EFI boots SATA DVDs reliably; IDE PIIX4 + EFI
# sometimes fails to enumerate the DVD as a boot device).
# Windows install ISO MUST be port 1 (first DVD): firmware boots bootmgr/setup from it.
# Autounattend-only ISO on port 2 is not a substitute boot image; putting it on
# port 1 causes EFI to target the wrong disc (flash/error), then unattended breaks.
# ---------------------------------------------------------------------------
Write-Headline "Mounting ISO(s)"
if ($AutounattendIso) {
    Write-Host "  + Windows install ISO at SATA port 1: $IsoPath"
    VBox storageattach $VmName --storagectl SATA --port 1 --device 0 --type dvddrive --medium $IsoPath
    Write-Host "  + Autounattend ISO at SATA port 2: $AutounattendIso"
    VBox storageattach $VmName --storagectl SATA --port 2 --device 0 --type dvddrive --medium $AutounattendIso
} else {
    Write-Host "  + Windows install ISO at SATA port 1: $IsoPath"
    VBox storageattach $VmName --storagectl SATA --port 1 --device 0 --type dvddrive --medium $IsoPath
}

# Boot order: DVD (Windows on port 1) before disk.
VBox modifyvm $VmName --boot1 dvd --boot2 disk --boot3 none --boot4 none
Write-MastTiming 'VDI + ISO mounts + boot order'

# ---------------------------------------------------------------------------
# Network: NAT (adapter 1) + host-only (adapter 2)
# ---------------------------------------------------------------------------
Write-Headline "Configuring network adapters"
$hostOnlyName = (VBox list hostonlyifs |
                 Select-String -Pattern '^Name:\s+(.+)$' |
                 ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } |
                 Where-Object { $_ } |
                 Select-Object -First 1)
if (-not $hostOnlyName) { throw "Could not parse host-only adapter name from 'VBoxManage list hostonlyifs'." }
Write-Host "  Host-only adapter: $hostOnlyName"

VBox modifyvm $VmName `
    --nic1 nat `
    --nictype1 82540EM `
    --nic2 hostonly `
    --hostonlyadapter2 $hostOnlyName `
    --nictype2 82540EM
Write-MastTiming 'Network adapters'

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host "`nVM '$VmName' created." -ForegroundColor Green

if ($AutounattendIso) {
    $nextSteps = @'

Next steps (autounattend mode):

  1) Start the VM (GUI mode if you want to watch progress):
       VBoxManage startvm {0} --type gui

     Within ~5 seconds, the Windows installer may show
       "Press any key to boot from CD or DVD..."
     Click the VM window and press Enter (if ignored, EFI may show a boot-failed dialog).

  2) Wait. Windows installs unattended (~15-25 min depending on the host).
     The answer file wipes disk 0, partitions GPT, installs Windows, and creates
     the factory admin (user / password1 by default). It does NOT auto-run bootstrap.

  3) Log in as that account. From the second DVD (often D: or E:), right-click
     bootstrap-winrm.cmd and choose Run as administrator (passes args through to PowerShell).
     Example from cmd.exe:
       D:\bootstrap-winrm.cmd -MastHostName mast05 -RebootAfterBootstrap
     (Use the drive letter that lists bootstrap-winrm.cmd; keep .cmd and .ps1 in the same folder.)
     Read the [OK] or [FAIL] summary; fix any USER ACTION lines and re-run if needed.

  4) After reboot if you used -RebootAfterBootstrap, log in as mast / physics.
     On the VirtualBox host (elevated): tools\sync-dev-unit-hosts.ps1 so mastNN resolves.

  5) Confirm WinRM from the host:
       Test-NetConnection mast05 -Port 5985

  6) Power the VM off cleanly, then:
       .\vbox-create-unit.ps1 -SnapshotOnly
'@
} else {
    $nextSteps = @'

Next steps (manual install):

  1) Start the VM (GUI mode for the Windows installer):
       VBoxManage startvm {0} --type gui

  2) Walk through Windows setup in the VM window.
     When done and at the desktop, inside the VM:
       - Prefer DHCP on the host-only adapter (enable VBox host-only DHCP or use
         a lease-friendly layout). Identity is the hostname (mast01), not a fixed IP.
       - Copy bootstrap-winrm.cmd, bootstrap-winrm.ps1, and npcap-*.exe together, then either:
           Right-click bootstrap-winrm.cmd -> Run as administrator
         or from an elevated cmd.exe:
             D:\bootstrap-winrm.cmd -MastHostName mast05
         Bootstrap does all first-time prep; there is no separate prepare step.

     (Copy scripts onto the VM via shared clipboard or a temporary VBox shared folder.)

  3) From this host (192.168.56.1) map mastNN to the VM address if needed, then:
       Test-NetConnection mast05 -Port 5985
       Test-NetConnection mast05 -Port 5986

  4) Power the VM off cleanly (shutdown from inside Windows), then:
       .\vbox-create-unit.ps1 -SnapshotOnly
     This takes the 'clean-state' and 'post-prepare' VirtualBox snapshots.

  Tip: skip the manual install entirely by first building an autounattend ISO:
       .\build-autounattend-iso.ps1
       .\vbox-create-unit.ps1 -IsoPath <win-iso> -AutounattendIso .\autounattend-mast.iso
'@
}
Write-Host ($nextSteps -f $VmName)
Write-MastTimingTotal '(create VM)'
