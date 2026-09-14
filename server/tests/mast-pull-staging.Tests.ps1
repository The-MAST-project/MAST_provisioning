# Pester unit tests for the pure decision logic in client/mast-pull-staging.ps1.
#
# Mirrors the Python tier (vm/tests): test the DECISIONS, not the I/O. The pull
# script is dot-sourced with no -SrcUNC, so its dot-source guard skips the live
# net use / robocopy and only its pure functions load -- no SMB, no unit, no
# mocking of the ecosystem.
#
# Run (Pester 3.x, shipped with Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\mast-pull-staging.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pullScript = Join-Path $here '..\..\client\mast-pull-staging.ps1'
. $pullScript   # defines Get-RobocopyOutcome / Test-StagingFits; main flow skipped

Describe 'Get-RobocopyOutcome' {
    It 'treats rc 0-7 as OK (success/info bits)' {
        Get-RobocopyOutcome -ExitCode 0 | Should Be 'OK'
        Get-RobocopyOutcome -ExitCode 1 | Should Be 'OK'
        Get-RobocopyOutcome -ExitCode 7 | Should Be 'OK'
    }
    It 'treats rc >= 8 as ROBOCOPY_ERROR (copy failures)' {
        Get-RobocopyOutcome -ExitCode 8  | Should Be 'ROBOCOPY_ERROR'
        Get-RobocopyOutcome -ExitCode 9  | Should Be 'ROBOCOPY_ERROR'
        Get-RobocopyOutcome -ExitCode 16 | Should Be 'ROBOCOPY_ERROR'
    }
}

Describe 'Test-StagingFits' {
    It 'is true when free space covers payload + margin' {
        Test-StagingFits -FreeBytes 20GB -PayloadBytes 16GB -MarginBytes 2GB | Should Be $true
    }
    It 'is false when free space is below payload + margin' {
        Test-StagingFits -FreeBytes 17GB -PayloadBytes 16GB -MarginBytes 2GB | Should Be $false
    }
    It 'defaults to a 2 GB margin' {
        # 16 GB payload needs 18 GB; 17 GB free fails, 19 GB free passes.
        Test-StagingFits -FreeBytes 17GB -PayloadBytes 16GB | Should Be $false
        Test-StagingFits -FreeBytes 19GB -PayloadBytes 16GB | Should Be $true
    }
    It 'is exact at the boundary (free == payload + margin fits)' {
        Test-StagingFits -FreeBytes 18GB -PayloadBytes 16GB -MarginBytes 2GB | Should Be $true
    }
}

Describe 'Get-MastRobocopyLogPath' {
    It 'lands the log in the per-run session dir the driver archives' {
        Get-MastRobocopyLogPath -UnitStage 'C:\mast-staging\run-20260826-101500' |
            Should Be 'C:\MAST\logs\sessions\run-20260826-101500\robocopy.log'
    }

    It 'keys the dir on the run id, which is the staging leaf' {
        Get-MastRobocopyLogPath -UnitStage 'D:\other\timingtest' |
            Should Be 'C:\MAST\logs\sessions\timingtest\robocopy.log'
    }
}

Describe 'Test-MastPayloadBytesUsable' {
    It 'refuses the unset default rather than guessing' {
        Test-MastPayloadBytesUsable -PayloadBytes -1 | Should Be $false
    }

    It 'accepts a real measured size' {
        Test-MastPayloadBytesUsable -PayloadBytes 14523011072 | Should Be $true
    }

    It 'accepts zero (an empty payload is a fact, not a missing value)' {
        Test-MastPayloadBytesUsable -PayloadBytes 0 | Should Be $true
    }
}

Describe 'Test-StagingFits with a junction-inclusive payload' {
    It 'refuses the 13.9 GB payload on a disk that the old 3.8 GB scan would have passed' {
        # The defect in one assertion: a unit with ~6 GB free passed the guard on
        # the understated size, then robocopy copied through the junctions and
        # needed 13.9 GB (issue 7, item 6).
        Test-StagingFits -FreeBytes 6GB -PayloadBytes 3.8GB | Should Be $true
        Test-StagingFits -FreeBytes 6GB -PayloadBytes 13.855GB | Should Be $false
    }
}

Describe 'Get-MastRobocopyExclusionArgs' {
    $src = '\\192.0.2.34\mast-staging\mast01\01-provisioning'

    It 'emits nothing when nothing is excluded' {
        # --force and a full run both arrive here with empty strings, and must
        # produce the argument list the payload had before #186.
        @(Get-MastRobocopyExclusionArgs -SrcUNC $src -ExcludeFiles '' -ExcludeDirs '').Count | Should Be 0
    }
    It 'roots each directory at the source UNC' {
        $a = Get-MastRobocopyExclusionArgs -SrcUNC $src -ExcludeFiles '' -ExcludeDirs 'mast-indexes|wheels'
        ($a -join ' ') | Should Be "/XD $src\mast-indexes $src\wheels"
    }
    It 'roots each file at the source UNC' {
        $a = Get-MastRobocopyExclusionArgs -SrcUNC $src -ExcludeFiles 'astrometry.tgz' -ExcludeDirs ''
        ($a -join ' ') | Should Be "/XF $src\astrometry.tgz"
    }
    It 'puts directories before files so each list is terminated by the next switch' {
        $a = Get-MastRobocopyExclusionArgs -SrcUNC $src -ExcludeFiles 'a.exe' -ExcludeDirs 'sxs'
        $a[0] | Should Be '/XD'
        $a[2] | Should Be '/XF'
    }
    It 'keeps a name containing spaces intact' {
        $a = Get-MastRobocopyExclusionArgs -SrcUNC $src -ExcludeFiles 'SAOImageDS9 8.7 Install.exe' -ExcludeDirs ''
        $a[1] | Should Be "$src\SAOImageDS9 8.7 Install.exe"
        @($a).Count | Should Be 2
    }
    It 'ignores empty segments and surrounding whitespace' {
        $a = Get-MastRobocopyExclusionArgs -SrcUNC $src -ExcludeFiles '' -ExcludeDirs '|wheels| |'
        ($a -join ' ') | Should Be "/XD $src\wheels"
    }
}

Describe 'Test-MastRobocopyCompleted' {
    # A robocopy that ran to completion always writes the Bytes:/Times:/Ended:
    # trailer; one killed partway never does. This discriminates exactly the case
    # the exit code cannot, because a taskkill'd robocopy also exits 1 (#189).
    It 'accepts a log ending in a real summary block' {
        $log = @'
   New File            123    ASIStudio_V1.16.2_x64_Setup.exe
------------------------------------------------------------------------------
               Total    Copied   Skipped  Mismatch    FAILED    Extras
    Bytes :  13.855 g  13.855 g         0         0         0         0
    Times :   0:04:42   0:04:41                       0:00:00   0:00:01
    Speed :            52856741 Bytes/sec.
    Ended : Wednesday, September 2, 2026 7:01:17 PM
'@
        Test-MastRobocopyCompleted -LogTail $log | Should Be $true
    }
    It 'rejects a log that stops mid-payload' {
        # The mast03 shape: 23 lines, no summary, 1.9% of the payload on disk.
        $log = @'
   New File          98.2 m    ASIStudio_V1.16.2_x64_Setup.exe
   New File          44.1 m    Git-2.52.0-64-bit.exe
'@
        Test-MastRobocopyCompleted -LogTail $log | Should Be $false
    }
    It 'rejects an empty or whitespace tail' {
        Test-MastRobocopyCompleted -LogTail '' | Should Be $false
        Test-MastRobocopyCompleted -LogTail "  `r`n " | Should Be $false
    }
    It 'requires the Ended line, not merely the word Bytes' {
        Test-MastRobocopyCompleted -LogTail "    Bytes :  13.855 g  13.855 g" | Should Be $false
    }
}

Describe 'Get-MastDirectorySize' {
    $root = Join-Path $env:TEMP ("mast-dirsize-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $root = (Get-Item -LiteralPath $root).FullName
    Set-Content -LiteralPath (Join-Path $root 'a.bin') -Value ('x' * 100) -Encoding Ascii -NoNewline
    $sub = Join-Path $root 'nested'
    New-Item -ItemType Directory -Force -Path $sub | Out-Null
    Set-Content -LiteralPath (Join-Path $sub 'b.bin') -Value ('y' * 250) -Encoding Ascii -NoNewline

    It 'counts files and bytes through nested directories' {
        $r = Get-MastDirectorySize -Path $root
        $r.Files | Should Be 2
        $r.Bytes | Should Be 350
    }
    It 'reports zero for a path that does not exist' {
        # A pull that never created the destination must read as 0, not throw --
        # the driver turns the comparison into TRANSFER_FAIL either way, and a
        # throw here would lose the numbers that say why.
        $r = Get-MastDirectorySize -Path (Join-Path $root 'no-such-dir')
        $r.Files | Should Be 0
        $r.Bytes | Should Be 0
    }
    It 'reports zero for an empty directory' {
        $empty = Join-Path $root 'empty'
        New-Item -ItemType Directory -Force -Path $empty | Out-Null
        (Get-MastDirectorySize -Path $empty).Files | Should Be 0
    }
}

Describe 'Get-RobocopyOutcome bitmask' {
    It 'treats 0-7 as success and 8+ as error' {
        Get-RobocopyOutcome -ExitCode 0 | Should Be 'OK'
        Get-RobocopyOutcome -ExitCode 1 | Should Be 'OK'
        Get-RobocopyOutcome -ExitCode 3 | Should Be 'OK'
        Get-RobocopyOutcome -ExitCode 7 | Should Be 'OK'
        Get-RobocopyOutcome -ExitCode 8 | Should Be 'ROBOCOPY_ERROR'
        Get-RobocopyOutcome -ExitCode 16 | Should Be 'ROBOCOPY_ERROR'
    }
}
