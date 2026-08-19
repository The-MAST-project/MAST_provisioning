#requires -Version 5.1
# Shared utility functions for MAST client-side scripts (bootstrap, prepare, onboard).
# Dot-source this file; do not run it directly. ASCII-only.

function Disable-WindowsAutoUpdate {
    $auPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    New-Item -Path $auPath -Force | Out-Null
    Set-ItemProperty -Path $auPath -Name NoAutoUpdate                 -Value 1 -Type DWord
    Set-ItemProperty -Path $auPath -Name AUOptions                    -Value 1 -Type DWord
    Set-ItemProperty -Path $auPath -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Set-Service  wuauserv -StartupType Disabled
}

# ---------------------------------------------------------------------------
# Hardware preflight helpers (pure; the CIM reads live in the caller)
# ---------------------------------------------------------------------------
# The fleet's 64 GB requirement is not a preference. server\providers\imdisk\
# provide-imdisk.ps1 mounts D: as a RAM-backed VOLATILE ImDisk (imdisk -t vm),
# and that attach COMMITS the image's full 32 GB of memory. Two hardware facts
# therefore have to be true before a unit is worth provisioning at all: enough
# RAM to host that mount, and a free D: for it to land on. Neither is visible
# from the payload -- a unit short on either does not fail early, it fails one
# ~13 GB transfer and ~250 modules later, at the imdisk attach.
#
# These are separated from the CIM reads so they can be exercised without a
# Windows unit (server\tests\mast-client-util.Tests.ps1).

function Test-MastMemoryRequirement {
    [CmdletBinding()]
    param(
        # Win32_ComputerSystem.TotalPhysicalMemory: memory the OS can see. It
        # reads a little UNDER the installed total on real hardware (firmware
        # reserve), which is why the comparison is against a floor rather than
        # the nominal figure. Win32_PhysicalMemory's capacity sum is the exact
        # installed total, but it enumerates nothing on some virtual firmware,
        # so it serves as the diagnostic breakdown, not the threshold.
        [Parameter(Mandatory)][long]$VisibleBytes,
        [Parameter(Mandatory)][int]$RequiredGB,
        # Firmware reserve allowance. Wide enough to absorb any real reserve,
        # far narrower than the gap between the two configurations that exist:
        # 64 GB passes, the 32 GB a unit ships with (or is left with by one
        # unseated DIMM) is nowhere near the floor.
        [double]$ReserveAllowancePct = 5.0
    )
    $floorBytes = [long][math]::Floor([double]$RequiredGB * 1GB * (1.0 - $ReserveAllowancePct / 100.0))
    return [pscustomobject]@{
        Ok         = ($VisibleBytes -ge $floorBytes)
        VisibleGB  = [math]::Round($VisibleBytes / 1GB, 1)
        FloorGB    = [math]::Round($floorBytes / 1GB, 1)
        RequiredGB = $RequiredGB
    }
}

function Get-MastDriveDVerdict {
    [CmdletBinding()]
    param(
        # Whether any device holds D: at all (a Win32_LogicalDisk for D:, or a
        # reachable D:\ -- a medialess drive answers only the first).
        [Parameter(Mandatory)][bool]$Present,
        # Win32_LogicalDisk.DriveType: 3 = local disk, 5 = CD-ROM.
        [int]$DriveType = 0,
        [string]$VolumeName = '',
        [Parameter(Mandatory)][string]$IndexVolumeLabel
    )
    if (-not $Present) { return 'free' }
    # Bootstrap is idempotent and gets re-run on units that are already
    # provisioned, where D: is the index mount imdisk put there. That is the
    # wanted state, not a conflict.
    if ($DriveType -eq 3 -and $VolumeName -eq $IndexVolumeLabel) { return 'index' }
    return 'foreign'
}
