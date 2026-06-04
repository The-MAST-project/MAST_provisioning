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
