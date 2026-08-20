# Pester unit tests for the pure helpers in client/mast-client-util.ps1.
#
# These are the hardware-preflight predicates bootstrap.ps1 gates a whole
# unit on, and the imdisk provider re-asserts before a '-t vm' mount. The CIM
# reads that feed them are the caller's; only the judgement is tested here.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\mast-client-util.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\..\client\mast-client-util.ps1')

Describe 'Test-MastMemoryRequirement' {
    It 'accepts an exactly-64 GiB read' {
        (Test-MastMemoryRequirement -VisibleBytes 68719476736 -RequiredGB 64).Ok | Should Be $true
    }
    It 'accepts a real 64 GB unit, which reports under 64 GiB (firmware reserve)' {
        # 68,451,041,280 bytes = 63.75 GiB, the shape of a real Win32_ComputerSystem read.
        (Test-MastMemoryRequirement -VisibleBytes 68451041280 -RequiredGB 64).Ok | Should Be $true
    }
    It 'rejects a 32 GB machine' {
        (Test-MastMemoryRequirement -VisibleBytes 34359738368 -RequiredGB 64).Ok | Should Be $false
    }
    It 'rejects the 8 GB dev VM' {
        (Test-MastMemoryRequirement -VisibleBytes 8589934592 -RequiredGB 64).Ok | Should Be $false
    }
    It 'rejects one unseated DIMM of a 2x32 GB pair' {
        (Test-MastMemoryRequirement -VisibleBytes 34293514240 -RequiredGB 64).Ok | Should Be $false
    }
    It 'puts the floor 5 percent under the requirement by default' {
        (Test-MastMemoryRequirement -VisibleBytes 68719476736 -RequiredGB 64).FloorGB | Should Be 60.8
    }
    It 'rejects a read just below the floor' {
        # 60.7 GiB, inside the requirement but under the allowance.
        (Test-MastMemoryRequirement -VisibleBytes 65176862720 -RequiredGB 64).Ok | Should Be $false
    }
    It 'honors a widened allowance' {
        (Test-MastMemoryRequirement -VisibleBytes 65176862720 -RequiredGB 64 -ReserveAllowancePct 10).Ok | Should Be $true
    }
    It 'reports the visible size in GB' {
        (Test-MastMemoryRequirement -VisibleBytes 34359738368 -RequiredGB 64).VisibleGB | Should Be 32
    }
    It 'echoes the requirement it was asked about' {
        (Test-MastMemoryRequirement -VisibleBytes 34359738368 -RequiredGB 64).RequiredGB | Should Be 64
    }
}

Describe 'Get-MastDriveDVerdict' {
    It 'calls an unassigned D: free' {
        Get-MastDriveDVerdict -Present $false -IndexVolumeLabel 'mast-indexes' | Should Be 'free'
    }
    It 'recognizes the index volume a provisioned unit already carries' {
        Get-MastDriveDVerdict -Present $true -DriveType 3 -VolumeName 'mast-indexes' -IndexVolumeLabel 'mast-indexes' |
            Should Be 'index'
    }
    It 'rejects a leftover data SSD on D:' {
        Get-MastDriveDVerdict -Present $true -DriveType 3 -VolumeName 'Data' -IndexVolumeLabel 'mast-indexes' |
            Should Be 'foreign'
    }
    It 'rejects an optical drive parked on D:' {
        Get-MastDriveDVerdict -Present $true -DriveType 5 -VolumeName '' -IndexVolumeLabel 'mast-indexes' |
            Should Be 'foreign'
    }
    It 'rejects a medialess device that answers with no logical disk' {
        # -Present comes from Test-Path D:\ in that case, so type and label are unknown.
        Get-MastDriveDVerdict -Present $true -IndexVolumeLabel 'mast-indexes' | Should Be 'foreign'
    }
    It 'does not accept the index label on a non-fixed drive' {
        Get-MastDriveDVerdict -Present $true -DriveType 5 -VolumeName 'mast-indexes' -IndexVolumeLabel 'mast-indexes' |
            Should Be 'foreign'
    }
    It 'recognizes the bootstrap medium it is running from' {
        # On a bare unit the USB takes D:, C: being the system disk.
        Get-MastDriveDVerdict -Present $true -DriveType 2 -VolumeName 'USB DISK' -IndexVolumeLabel 'mast-indexes' -RunningFromD $true |
            Should Be 'self'
    }
    It 'calls a removable D: removable when it is not the medium in hand' {
        Get-MastDriveDVerdict -Present $true -DriveType 2 -VolumeName 'USB DISK' -IndexVolumeLabel 'mast-indexes' -RunningFromD $false |
            Should Be 'removable'
    }
    It 'still recognizes the index volume when running from D:' {
        # A re-run on a provisioned unit, from a copy on the index disk itself.
        Get-MastDriveDVerdict -Present $true -DriveType 3 -VolumeName 'mast-indexes' -IndexVolumeLabel 'mast-indexes' -RunningFromD $true |
            Should Be 'index'
    }
    It 'does not excuse a fitted disk just because the script runs from D:' {
        # The operator who copies the payload onto the factory D: SSD and runs
        # it from there is looking at the exact disk that has to come out. An
        # earlier ordering returned 'self' here, which would have passed the
        # check on the machine it exists to stop.
        Get-MastDriveDVerdict -Present $true -DriveType 3 -VolumeName 'Data' -IndexVolumeLabel 'mast-indexes' -RunningFromD $true |
            Should Be 'foreign'
    }
}

Describe 'Get-MastBootstrapExitCode' {
    It 'returns 0 when nothing blocked the run' {
        Get-MastBootstrapExitCode -Blockers @() | Should Be 0
    }
    It 'returns 0 when the parameter is omitted entirely' {
        Get-MastBootstrapExitCode | Should Be 0
    }
    It 'returns 1 for a single blocker' {
        Get-MastBootstrapExitCode -Blockers @('sshd is not registered') | Should Be 1
    }
    It 'returns 1 for several blockers' {
        Get-MastBootstrapExitCode -Blockers @('sshd is not registered', 'sshd_config missing') | Should Be 1
    }
    It 'ignores empty and whitespace entries' {
        # An accidental '+= $null' or '+= ""' must not fail an otherwise clean
        # run: the exit code is the operator's signal, so a false 1 costs as
        # much trust as a false 0.
        Get-MastBootstrapExitCode -Blockers @('', '   ', $null) | Should Be 0
    }
    It 'still fails when a real blocker sits among empty entries' {
        Get-MastBootstrapExitCode -Blockers @('', 'sshd is not registered', $null) | Should Be 1
    }
}
