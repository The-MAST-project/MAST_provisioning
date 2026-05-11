<#
.SYNOPSIS
  Build an Autounattend ISO that drives an unattended Windows install on a
  fresh MAST unit (physical or VirtualBox).

.DESCRIPTION
  The output ISO contains:
    - Autounattend.xml at the root (Windows Setup auto-detects this on any
      attached drive: ISO, USB, or floppy).
  - client\bootstrap-winrm.cmd and bootstrap-winrm.ps1 at the ISO root for the
    operator to run manually after first login (USB/DVD copy is fine). Use the
    .cmd so Windows runs PowerShell instead of Notepad (default .ps1 association).
    They are not executed from FirstLogonCommands. After bootstrap succeeds, the
    prov server may run prepare-mast-client.ps1 over WinRM.

  Mount this ISO as a second DVD drive in the unit VM (vbox-create-unit.ps1
  does this automatically when -AutounattendIso is supplied), then start
  the VM. Windows Setup picks up Autounattend.xml from any attached drive
  with no operator interaction.

  This script depends on:
    - Windows PowerShell 5.1 (Add-Type -CompilerParameters / CodeDom)
    - IMAPI2FS COM (built into Windows 7+, no install required)
    - The C# compiler that ships with .NET Framework 4.x

.PARAMETER OutputIso
  Where to write the final ISO. Default: <repo>\autounattend-mast.iso

.PARAMETER Architecture
  amd64 or arm64. Defaults to the architecture of the *host* shell, but
  the answer file targets the *guest*; override when building for an
  ARM64 unit from an x64 host.

.PARAMETER MastUser, MastPassword
  Local admin account created by the answer file (factory/OEM defaults).
  Defaults: user / password1 - simulates a generic machine from the factory.
  The operator runs client\bootstrap-winrm.cmd (or .ps1 in PowerShell) with -MastHostName mastNN; it renames user -> mast,
  sets physics, enables WinRM (matches vault/creds.json), and renames the computer to mastNN.

.PARAMETER WindowsEdition
  Optional <InstallFrom> filter when the install ISO has multiple editions (required
  for autonomous setup on typical IoT LTSC ISOs or you get the Select Image wizard).
  The Value must match an image Name from:
    dism /Get-WimInfo /WimFile:X:\sources\install.wim
  Common IoT LTSC name: Windows 11 IoT Enterprise LTSC (verify with DISM).
  If omitted and the WIM has one image only, Setup picks it; multiple images without this stay interactive.

.PARAMETER Locale
  System / UI / user locale. Default 'en-US'.

.PARAMETER InputLocale
  Keyboard. Default '0409:00000409' (US English).

.PARAMETER TimeZone
  Default 'Israel Standard Time'. Use tzutil /l on a Windows box for the list.

.PARAMETER ProductKey
  Optional. If set, adds `<ProductKey>` with WillShowUI Never.
  Use Microsoft's KMS *client setup* key for your edition from Learn (volume channel;
  not a license substitute). Multi-edition LTSC ISOs often need this plus -WindowsEdition.
  If omitted, no ProductKey element is written (product key wizard may appear).

.PARAMETER VolumeLabel
  ISO volume label. Default 'MAST_AU'. Must be <= 16 chars (Joliet limit).

.PARAMETER FactoryComputerName
  NetBIOS computer name written during specialize (max 15 chars).
  Default (omit): OEM + 12 hex chars, unique each time you build the ISO - mimics
  a generic factory serial. Pass '*' to let Windows pick a random name at install
  time (legacy behavior). The operator-chosen mastNN name is applied by bootstrap-winrm.ps1;
  prepare-mast-client.ps1 aligns HTTPS and steady-state remoting.

.PARAMETER ExtraScripts
  Optional list of extra files to copy into the ISO root (in addition to
  bootstrap-winrm.cmd and bootstrap-winrm.ps1). Useful for shipping prepare-mast-client.ps1 or
  onboard-mast-unit.ps1.

.EXAMPLE
  # Build with all defaults, drop next to the repo:
  .\build-autounattend-iso.ps1

  # ARM64 IoT LTSC unit, custom output path:
  .\build-autounattend-iso.ps1 -Architecture arm64 -WindowsEdition "Windows 11 IoT Enterprise LTSC" -OutputIso C:\ISOs\autounattend-mast-arm64.iso

  # Bundle onboarding script too (so a physical unit can run onboard from D:)
  .\build-autounattend-iso.ps1 -ExtraScripts client\onboard-mast-unit.ps1
#>

[CmdletBinding()]
param(
    [string]   $OutputIso       = '',
    [ValidateSet('amd64','arm64')]
    [string]   $Architecture    = $(if ($env:PROCESSOR_ARCHITECTURE -ieq 'arm64') {'arm64'} else {'amd64'}),
    [string]   $MastUser        = 'user',
    [string]   $MastPassword    = 'password1',
    [string]   $WindowsEdition  = '',
    [string]   $Locale          = 'en-US',
    [string]   $InputLocale     = '0409:00000409',
    [string]   $TimeZone        = 'Israel Standard Time',
    [string]   $ProductKey      = '',
    [string]   $VolumeLabel     = 'MAST_AU',
    [string]   $FactoryComputerName = '',
    [string[]] $ExtraScripts    = @()
)

$ErrorActionPreference = 'Stop'
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot }
            elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
            elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
            else { (Get-Location).Path }
if (-not $OutputIso) { $OutputIso = Join-Path $RepoRoot 'autounattend-mast.iso' }

function Write-Headline($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

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

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
if ($VolumeLabel.Length -gt 16) {
    throw "VolumeLabel '$VolumeLabel' is longer than 16 chars (Joliet limit)."
}

# Factory hostname: OEM + 12 hex (15 chars NETBIOS max), or '*' for Windows random
if ([string]::IsNullOrWhiteSpace($FactoryComputerName)) {
    $resolvedComputerName = 'OEM' + ([guid]::NewGuid().ToString('N').Substring(0, 12))
} elseif ($FactoryComputerName.Trim() -eq '*') {
    $resolvedComputerName = '*'
} else {
    $resolvedComputerName = $FactoryComputerName.Trim()
    if ($resolvedComputerName.Length -lt 1 -or $resolvedComputerName.Length -gt 15) {
        throw "FactoryComputerName must be 1-15 characters or '*': got '$resolvedComputerName'"
    }
}

$bootstrapPath = Join-Path $RepoRoot 'client\bootstrap-winrm.ps1'
$bootstrapCmdPath = Join-Path $RepoRoot 'client\bootstrap-winrm.cmd'
if (-not (Test-Path $bootstrapPath)) {
    throw "bootstrap-winrm.ps1 not found at $bootstrapPath"
}
if (-not (Test-Path $bootstrapCmdPath)) {
    throw "bootstrap-winrm.cmd not found at $bootstrapCmdPath"
}

$resolvedExtras = @()
foreach ($s in $ExtraScripts) {
    $candidate = if ([System.IO.Path]::IsPathRooted($s)) { $s } else { Join-Path $RepoRoot $s }
    if (-not (Test-Path $candidate)) {
        throw "Extra script not found: $candidate"
    }
    $resolvedExtras += (Resolve-Path $candidate).Path
}

# ---------------------------------------------------------------------------
# Build Autounattend.xml in memory
# ---------------------------------------------------------------------------
Write-Headline "Generating Autounattend.xml (arch=$Architecture, locale=$Locale, tz=$TimeZone, ComputerName=$resolvedComputerName)"

# Optional <InstallFrom> block
$installFrom = ''
if ($WindowsEdition) {
    $installFrom = @"
                <InstallFrom>
                    <MetaData wcm:action="add">
                        <Key>/IMAGE/NAME</Key>
                        <Value>$WindowsEdition</Value>
                    </MetaData>
                </InstallFrom>
"@
}

$productKeyBlock = ''
if ($ProductKey) {
    $pk = $ProductKey.Trim()
    $productKeyBlock = @"
                <ProductKey>
                  <WillShowUI>Never</WillShowUI>
                  <Key>$pk</Key>
                </ProductKey>
"@
}

$xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="$Architecture" publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <SetupUILanguage>
        <UILanguage>$Locale</UILanguage>
      </SetupUILanguage>
      <InputLocale>$InputLocale</InputLocale>
      <UILanguage>$Locale</UILanguage>
      <SystemLocale>$Locale</SystemLocale>
      <UserLocale>$Locale</UserLocale>
    </component>

    <component name="Microsoft-Windows-Setup"
               processorArchitecture="$Architecture" publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
          <InstallToAvailablePartition>false</InstallToAvailablePartition>
$installFrom
        </OSImage>
      </ImageInstall>
      <UserData>
$productKeyBlock
        <AcceptEula>true</AcceptEula>
        <FullName>MAST</FullName>
        <Organization>MAST</Organization>
      </UserData>
    </component>
  </settings>

  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="$Architecture" publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <ComputerName>$resolvedComputerName</ComputerName>
      <TimeZone>$TimeZone</TimeZone>
    </component>
    <component name="Microsoft-Windows-Deployment"
               processorArchitecture="$Architecture" publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Bypass Windows 11 OOBE Microsoft-account requirement</Description>
          <Path>reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>

  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="$Architecture" publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipUserOOBE>true</SkipUserOOBE>
        <SkipMachineOOBE>true</SkipMachineOOBE>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$MastUser</Name>
            <DisplayName>$MastUser</DisplayName>
            <Group>Administrators</Group>
            <Password>
              <Value>$MastPassword</Value>
              <PlainText>true</PlainText>
            </Password>
            <Description>MAST provisioning admin</Description>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
    </component>
  </settings>

</unattend>
"@

# ---------------------------------------------------------------------------
# Stage files in a temp dir
# ---------------------------------------------------------------------------
$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("autounattend-stage-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $staging | Out-Null
try {
    $phaseSw.Restart()
    $xmlPath = Join-Path $staging 'Autounattend.xml'
    [System.IO.File]::WriteAllText($xmlPath, $xml, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  Staged Autounattend.xml ($([int]((Get-Item $xmlPath).Length / 1KB)) KB)"

    Copy-Item -Force $bootstrapPath (Join-Path $staging 'bootstrap-winrm.ps1')
    Write-Host "  Staged bootstrap-winrm.ps1"
    Copy-Item -Force $bootstrapCmdPath (Join-Path $staging 'bootstrap-winrm.cmd')
    Write-Host "  Staged bootstrap-winrm.cmd"

    foreach ($extra in $resolvedExtras) {
        $name = Split-Path $extra -Leaf
        Copy-Item -Force $extra (Join-Path $staging $name)
        Write-Host "  Staged $name"
    }

    Write-MastTiming 'Generate XML + stage payload'

    # -----------------------------------------------------------------------
    # Build the ISO via IMAPI2FS COM
    # -----------------------------------------------------------------------
    Write-Headline "Building ISO via IMAPI2FS"

    # Helper class: copy IStream -> FileStream. Memory-safe (no /unsafe needed).
    if (-not ('MastIsoHelper' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class MastIsoHelper {
    public static void Write(string path, object srcObj, int blockSize, int totalBlocks) {
        IStream src = (IStream)srcObj;
        byte[] buf = new byte[blockSize];
        IntPtr pcbRead = Marshal.AllocHGlobal(IntPtr.Size);
        try {
            using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write)) {
                long blocksLeft = totalBlocks;
                while (blocksLeft > 0) {
                    src.Read(buf, blockSize, pcbRead);
                    int n = Marshal.ReadInt32(pcbRead);
                    if (n <= 0) break;
                    fs.Write(buf, 0, n);
                    blocksLeft--;
                }
                fs.Flush();
            }
        } finally {
            Marshal.FreeHGlobal(pcbRead);
        }
    }
}
'@
    }

    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    # FileSystemsToCreate: 1=ISO9660, 2=Joliet, 4=UDF; 7 = all three.
    $image.FileSystemsToCreate = 7
    $image.VolumeName = $VolumeLabel
    $image.FreeMediaBlocks = 0   # unbounded
    $image.Root.AddTree($staging, $false)

    $result = $image.CreateResultImage()
    Write-Host "  Image: $($result.BlockSize) bytes/block * $($result.TotalBlocks) blocks = $([int](($result.BlockSize * $result.TotalBlocks) / 1KB)) KB"

    $outDir = Split-Path -Parent $OutputIso
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

    [MastIsoHelper]::Write($OutputIso, $result.ImageStream, $result.BlockSize, $result.TotalBlocks)

    Write-MastTiming 'Build ISO (IMAPI2FS + write file)'

    Write-Host ""
    Write-Host "Wrote: $OutputIso" -ForegroundColor Green
    Write-Host "Size:  $([int]((Get-Item $OutputIso).Length / 1KB)) KB"
    Write-Host ""
    Write-Host "Mount alongside the Windows install ISO. Examples:"
    Write-Host "  .\vbox-create-unit.ps1 -IsoPath <win-iso> -AutounattendIso `"$OutputIso`""
    Write-Host "  VBoxManage storageattach mast-unit --storagectl SATA --port 2 --device 0 --type dvddrive --medium `"$OutputIso`""
    Write-MastTimingTotal 'build-autounattend-iso.ps1'
}
finally {
    Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
}
