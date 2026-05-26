#requires -Version 5.1
<#
.SYNOPSIS
  Populate this directory with the NetFx3 SxS files from a Windows IoT 11
  LTSC 2024 ISO. Run this once per Windows servicing release.

.DESCRIPTION
  Microsoft does not publish stable direct-download URLs for individual
  Feature-on-Demand .cab files. The NetFx3 payload ships only inside the
  Windows installation ISO (`sources\sxs\`) or the merged Languages and
  Optional Features ISO. Both are signed downloads from:

    Microsoft Evaluation Center  (free 90-day eval, MSA sign-in)
    https://www.microsoft.com/en-us/evalcenter/download-windows-11-iot-enterprise-ltsc-eval

    Volume Licensing Service Center (production licensing)

  Once the operator has downloaded the ISO once, this script automates the
  rest: mount the ISO, copy the NetFx3 SxS files, verify, unmount.

.PARAMETER IsoPath
  Path to the downloaded ISO. The script will Mount-DiskImage it and
  unmount when done.

.PARAMETER IsoDrive
  Alternative to -IsoPath: drive letter (e.g. 'E:') of an already-mounted
  ISO. The script copies from <Drive>\sources\sxs and does NOT touch the
  mount.

.PARAMETER SxsRoot
  Path to a manually-extracted sources\sxs\ directory. Useful when the
  operator has the SxS files but not a mountable ISO. The script just
  copies; no mount management.

.EXAMPLE
  .\fetch-from-iso.ps1 -IsoPath 'C:\downloads\Windows11_IoT_LTSC_2024.iso'

.EXAMPLE
  # ISO already mounted via File Explorer or PowerShell:
  .\fetch-from-iso.ps1 -IsoDrive 'E:'

.NOTES
  Validation: at least one matching .cab present after copy. Pinned name
  prefix is 'microsoft-windows-netfx3-ondemand-package'.
#>

[CmdletBinding(DefaultParameterSetName = 'IsoPath')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'IsoPath')]
    [string]$IsoPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'IsoDrive')]
    [string]$IsoDrive,
    [Parameter(Mandatory = $true, ParameterSetName = 'SxsRoot')]
    [string]$SxsRoot
)

$ErrorActionPreference = 'Stop'
$destDir = $PSScriptRoot   # this script lives at assets\sxs\fetch-from-iso.ps1
$cabPattern = 'microsoft-windows-netfx3-ondemand-package*'

function Copy-Sxs {
    param([string]$Source)
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Source directory not found: $Source"
    }
    $cabs = @(Get-ChildItem -LiteralPath $Source -Filter "$cabPattern.cab" -File -ErrorAction SilentlyContinue)
    if ($cabs.Count -eq 0) {
        throw "No '$cabPattern*.cab' files found under $Source. Wrong directory? On a Windows ISO the relative path is 'sources\sxs\'."
    }
    Write-Host ("Found {0} NetFx3 cab file(s) under {1}." -f $cabs.Count, $Source)

    # Mirror the directory contents (cab + manifests + .mum/.cat). Keep the
    # original tree shape so DISM sees a normal sources\sxs layout.
    foreach ($item in Get-ChildItem -LiteralPath $Source -File) {
        $dest = Join-Path $destDir $item.Name
        Copy-Item -LiteralPath $item.FullName -Destination $dest -Force
        Write-Host ("  copied {0} ({1:N0} bytes)" -f $item.Name, $item.Length)
    }
}

switch ($PSCmdlet.ParameterSetName) {
    'IsoPath' {
        if (-not (Test-Path -LiteralPath $IsoPath)) {
            throw "ISO not found: $IsoPath"
        }
        Write-Host ("Mounting ISO: {0}" -f $IsoPath)
        $img = Mount-DiskImage -ImagePath $IsoPath -PassThru
        try {
            Start-Sleep -Seconds 1
            $vol = $img | Get-Volume
            $drive = $vol.DriveLetter
            if (-not $drive) {
                throw "Mounted ISO has no drive letter; aborting."
            }
            $drive = "${drive}:"
            Write-Host ("ISO mounted at {0}" -f $drive)
            Copy-Sxs -Source (Join-Path $drive 'sources\sxs')
        }
        finally {
            Write-Host ("Dismounting {0}" -f $IsoPath)
            Dismount-DiskImage -ImagePath $IsoPath | Out-Null
        }
    }
    'IsoDrive' {
        if (-not (Test-Path -LiteralPath $IsoDrive)) {
            throw "Drive not found / not a path: $IsoDrive"
        }
        Copy-Sxs -Source (Join-Path $IsoDrive 'sources\sxs')
    }
    'SxsRoot' {
        Copy-Sxs -Source $SxsRoot
    }
}

# Verification
$staged = @(Get-ChildItem -LiteralPath $destDir -Filter "$cabPattern.cab" -File -ErrorAction SilentlyContinue)
if ($staged.Count -eq 0) {
    throw "Post-copy verification failed: no $cabPattern*.cab present in $destDir."
}
$total = ($staged | Measure-Object -Property Length -Sum).Sum
Write-Host ""
Write-Host ("DONE. Staged {0} NetFx3 cab file(s), total {1:N0} bytes under {2}" -f $staged.Count, $total, $destDir)
Write-Host ("Largest cab: {0} ({1:N0} bytes)" -f $staged[0].Name, $staged[0].Length)
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Re-run build (build-mast.ps1 will now find the bundled SxS and not require -AllowMissingNetFx3Sxs)."
Write-Host "  2. On the unit, ASCOM provider will log '[ascom] NetFx3 source: bundled SxS at ...' instead of the online-DISM warning."
