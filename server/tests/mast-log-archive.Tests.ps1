# Pester unit tests for the pure retention logic in server/lib/mast-log-archive.ps1.
# The filesystem runner (Invoke-MastProvRetention) is exercised on a real unit;
# the delete DECISION is what a bug would silently get wrong, so it is tested here.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\mast-log-archive.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\lib\mast-log-archive.ps1')

Describe 'Get-RunIdTimestamp' {
    It 'extracts the sortable stamp from a conforming run id' {
        Get-RunIdTimestamp 'run-20260712-091200' | Should Be '20260712-091200'
    }
    It 'returns $null for a non-conforming name' {
        Get-RunIdTimestamp 'scratch'          | Should Be $null
        Get-RunIdTimestamp 'run-2026'         | Should Be $null
        Get-RunIdTimestamp 'run-20260712-0912' | Should Be $null
    }
}

Describe 'Select-MastProvPrunableRuns' {
    It 'returns nothing when at or under the retain count' {
        $ids = @('run-20260712-010000','run-20260712-020000','run-20260712-030000')
        @(Select-MastProvPrunableRuns -RunIds $ids -Retain 3).Count | Should Be 0
        @(Select-MastProvPrunableRuns -RunIds $ids -Retain 5).Count | Should Be 0
    }
    It 'keeps the newest N and prunes the rest (chronological by stamp)' {
        $ids = @(
            'run-20260710-090000','run-20260712-090000','run-20260711-090000',
            'run-20260709-090000','run-20260708-090000'
        )
        $prune = @(Select-MastProvPrunableRuns -RunIds $ids -Retain 2)
        # Newest two (0712, 0711) kept; the older three pruned.
        $prune.Count | Should Be 3
        ($prune -contains 'run-20260712-090000') | Should Be $false
        ($prune -contains 'run-20260711-090000') | Should Be $false
        ($prune -contains 'run-20260710-090000') | Should Be $true
        ($prune -contains 'run-20260708-090000') | Should Be $true
    }
    It 'never prunes non-conforming names (unknown provenance is left alone)' {
        $ids = @('run-20260712-090000','run-20260711-090000','scratch','manual-copy')
        $prune = Select-MastProvPrunableRuns -RunIds $ids -Retain 1
        # Only the older conforming id is prunable; the two odd names are ignored.
        $prune | Should Be @('run-20260711-090000')
    }
    It 'always keeps the current (newest) run at Retain=1' {
        $ids = @('run-20260712-235959','run-20260712-000000')
        Select-MastProvPrunableRuns -RunIds $ids -Retain 1 | Should Be @('run-20260712-000000')
    }
    It 'throws on a Retain below 1' {
        { Select-MastProvPrunableRuns -RunIds @('run-20260712-090000') -Retain 0 } | Should Throw
    }
}
