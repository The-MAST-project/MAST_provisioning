# Pester unit tests for the pure verdict logic in server/lib/mast-git-currency.ps1.
#
# The whole point of extracting these from verify-mast.ps1 is that the decision
# table is exercised rather than reviewed. #177 existed because one branch of the
# old table (remote unreachable) silently took the "current" path, and a false
# "current" costs exactly as much operator trust as a false "stale".
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\mast-git-currency.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\lib\mast-git-currency.ps1')

$SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$SHA_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$WHEN  = '2026-08-31T12:37:00Z'

Describe 'Get-MastCurrencyVerdict -- origin reachable' {
    It 'is current when HEAD matches what origin reports' {
        $v = Get-MastCurrencyVerdict -Dir 'common' -HeadSha $SHA_A -RemoteSha $SHA_A
        $v.State | Should Be 'current'
        $v.Message | Should Match 'origin agrees'
    }
    It 'is stale when origin reports a different revision' {
        $v = Get-MastCurrencyVerdict -Dir 'common' -HeadSha $SHA_A -RemoteSha $SHA_B
        $v.State | Should Be 'stale'
        $v.Message | Should Match 'behind its remote'
    }
    It 'prefers the live answer over the sidecar when both are present' {
        # fetch_ok says a past run verified it; origin says it has moved since.
        # The live answer wins -- the sidecar is fallback evidence, not a veto.
        $v = Get-MastCurrencyVerdict -Dir 'unit' -HeadSha $SHA_A -RemoteSha $SHA_B -FetchOk $true -VerifiedAt $WHEN
        $v.State | Should Be 'stale'
    }
}

Describe 'Get-MastCurrencyVerdict -- origin unreachable' {
    It 'is unverifiable when the sidecar says a past run did verify this SHA' {
        $v = Get-MastCurrencyVerdict -Dir 'common' -HeadSha $SHA_A -RemoteSha '' -FetchOk $true -VerifiedAt $WHEN
        $v.State | Should Be 'unverifiable'
    }
    It 'names WHEN the last real verification happened, so the caveat has an age' {
        $v = Get-MastCurrencyVerdict -Dir 'common' -HeadSha $SHA_A -RemoteSha '' -FetchOk $true -VerifiedAt $WHEN
        $v.Message | Should Match ([regex]::Escape($WHEN))
        $v.Message | Should Match 'not a currency check'
    }
    It 'still reports an age when the sidecar carries no written_at' {
        $v = Get-MastCurrencyVerdict -Dir 'common' -HeadSha $SHA_A -RemoteSha '' -FetchOk $true
        $v.State | Should Be 'unverifiable'
        $v.Message | Should Match 'unrecorded time'
    }
    It 'is unverified -- a FAILURE -- when the sidecar says the fetch failed too' {
        # This is the #175 state itself: nothing has ever confirmed the checkout.
        $v = Get-MastCurrencyVerdict -Dir 'common' -HeadSha $SHA_A -RemoteSha '' -FetchOk $false -VerifiedAt $WHEN
        $v.State | Should Be 'unverified'
        $v.Message | Should Match 'fetch_ok=false'
    }
    It 'is unverified when there is no fetch_ok at all, and says so differently' {
        # A pre-#176 sidecar, or none: distinguishable from a recorded failure.
        $v = Get-MastCurrencyVerdict -Dir 'common' -HeadSha $SHA_A -RemoteSha '' -FetchOk $null
        $v.State | Should Be 'unverified'
        $v.Message | Should Match 'no fetch_ok in clone-manifest.json'
    }
}

Describe 'Get-MastVerifyExitCode' {
    It 'is 0 for a clean run' {
        Get-MastVerifyExitCode -IssueCount 0 -UnverifiableCount 0 | Should Be 0
    }
    It 'is 1 when anything actually failed' {
        Get-MastVerifyExitCode -IssueCount 1 -UnverifiableCount 0 | Should Be 1
    }
    It 'is 2 when nothing failed but something could not be checked' {
        Get-MastVerifyExitCode -IssueCount 0 -UnverifiableCount 1 | Should Be 2
    }
    It 'prefers 1 over 2 when a run has both' {
        # A concrete failure is the actionable half; an unanswered question must not
        # mask it.
        Get-MastVerifyExitCode -IssueCount 1 -UnverifiableCount 3 | Should Be 1
    }
    It 'defaults to 0 with no arguments' {
        Get-MastVerifyExitCode | Should Be 0
    }
}
