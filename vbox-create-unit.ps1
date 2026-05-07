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
       - Configure static IP 192.168.56.20/24, gateway 192.168.56.1 on
         the host-only adapter
       - Run bootstrap-winrm.ps1 (creates 'mast' user, enables WinRM)
       - Run prepare-mast-client.ps1 -HostName mast01 -Provider 192.168.56.1
       - Verify WinRM reachability from this host (the prov server) on
         port 5985 and 5986
    D. Power off cleanly, then come back here and run:
         vbox-create-unit.ps1 -SnapshotOnly
       to take the 'clean-state' and 'post-prepare' snapshots.

.PARAMETER IsoPath
  Path to a Windows 11 / Windows IoT LTSC install ISO. Required unless
  -SnapshotOnly is specified.

.PARAMETER AutounattendIso
  Optional. Path to an autounattend ISO (built by build-autounattend-iso.ps1).
  When supplied, mounts it on the IDE controller's secondary slot so Windows
  Setup picks up Autounattend.xml automatically. Skips the manual install
  walkthrough entirely; FirstLogonCommands runs bootstrap-winrm.ps1 from
  the ISO so WinRM is reachable from the prov server on first boot.

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

# ---------------------------------------------------------------------------
# Snapshot-only mode
# ---------------------------------------------------------------------------
if ($SnapshotOnly) {
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
    Write-Host "`nSnapshots ready. Restore with:"
    Write-Host "  VBoxManage controlvm $VmName poweroff"
    Write-Host "  VBoxManage snapshot $VmName restore post-prepare"
    Write-Host "  VBoxManage startvm $VmName --type headless"
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
    Write-Warning "No host-only network with 192.168.56.1 found. Create one in VirtualBox > Tools > Network Manager (subnet 192.168.56.0/24, DHCP off), then re-run."
    exit 1
}

if (Test-VmExists $VmName) {
    Write-Host "VM '$VmName' already exists -- skipping creation steps."
    Write-Host "Delete it first if you want to recreate: VBoxManage unregistervm $VmName --delete"
    exit 0
}

# ---------------------------------------------------------------------------
# Create VM
# ---------------------------------------------------------------------------
Write-Headline "Creating VM '$VmName'"
VBox createvm --name $VmName --ostype Windows11_64 --register

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
# ---------------------------------------------------------------------------
Write-Headline "Mounting Windows ISO"
VBox storageattach $VmName --storagectl SATA --port 1 --device 0 --type dvddrive --medium $IsoPath

if ($AutounattendIso) {
    Write-Host "  + Autounattend ISO at SATA port 2: $AutounattendIso"
    VBox storageattach $VmName --storagectl SATA --port 2 --device 0 --type dvddrive --medium $AutounattendIso
}

# Boot order: DVD first so Windows installer launches on first boot
VBox modifyvm $VmName --boot1 dvd --boot2 disk --boot3 none --boot4 none

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

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host "`nVM '$VmName' created." -ForegroundColor Green

if ($AutounattendIso) {
    $nextSteps = @'

Next steps (autounattend mode):

  1) Start the VM (GUI mode if you want to watch progress):
       VBoxManage startvm {0} --type gui

     Within ~5 seconds, the Windows installer shows
       "Press any key to boot from CD or DVD..."
     If ignored, EFI gives up and shows a boot-failed dialog. Send Enter:
       Start-Sleep 5; VBoxManage controlvm {0} keyboardputscancode 1c 9c

  2) Wait. Windows installs unattended (~15-25 min depending on host).
     The answer file + bootstrap-winrm.ps1 do all of:
       - Wipe disk 0, partition GPT, install Windows
       - Create the 'mast' admin account
       - Pin the host-only NIC to static 192.168.56.20/24
       - Bring up WinRM HTTP + Basic on port 5985

  3) From this host confirm WinRM reachability:
       Test-NetConnection 192.168.56.20 -Port 5985

  4) Run prepare-mast-client.ps1 remotely from the prov server to finish
     hostname rename + WinRM HTTPS:
       $cred = Get-Credential   # mast / physics
       Invoke-Command -ComputerName 192.168.56.20 -Credential $cred ``
           -FilePath .\client\prepare-mast-client.ps1 ``
           -ArgumentList @{HostName='mast01'; Provider='192.168.56.1'}

  5) Power the VM off cleanly, then:
       .\vbox-create-unit.ps1 -SnapshotOnly
'@
} else {
    $nextSteps = @'

Next steps (manual install):

  1) Start the VM (GUI mode for the Windows installer):
       VBoxManage startvm {0} --type gui

  2) Walk through Windows setup in the VM window.
     When done and at the desktop, inside the VM:
       - Open Settings, then Network, then Ethernet (host-only adapter):
           IP:      192.168.56.20
           Mask:    255.255.255.0
           Gateway: 192.168.56.1
       - Open an admin PowerShell and run, in this order:
             Set-ExecutionPolicy Bypass -Scope Process -Force
             .\bootstrap-winrm.ps1
             .\prepare-mast-client.ps1 -HostName mast01 -Provider 192.168.56.1

     (Copy these two scripts onto the VM via shared clipboard or a
      temporary VBox shared folder.)

  3) From this host (192.168.56.1) confirm WinRM reachability:
       Test-NetConnection 192.168.56.20 -Port 5985
       Test-NetConnection 192.168.56.20 -Port 5986

  4) Power the VM off cleanly (shutdown from inside Windows), then:
       .\vbox-create-unit.ps1 -SnapshotOnly
     This takes the 'clean-state' and 'post-prepare' VirtualBox snapshots.

  Tip: skip the manual install entirely by first building an autounattend ISO:
       .\build-autounattend-iso.ps1
       .\vbox-create-unit.ps1 -IsoPath <win-iso> -AutounattendIso .\autounattend-mast.iso
'@
}
Write-Host ($nextSteps -f $VmName)
