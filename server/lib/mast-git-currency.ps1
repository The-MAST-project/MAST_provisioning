#requires -Version 5.1
<#
.SYNOPSIS
  Decide whether a clone is at the revision its remote actually reports.

.DESCRIPTION
  Pure verdict logic, separated from the git calls and the logging so it can be
  Pester-tested. Same reasoning as Get-MastBootstrapExitCode in
  mast-client-util.ps1: a wrong verdict here costs operator trust either way, so
  the decision table is exercised rather than reviewed.

  WHY THIS EXISTS AT ALL: verify-mast.ps1 used to establish currency by comparing
  HEAD against '@{u}'. That is the remote-TRACKING ref -- a purely local pointer
  nothing updates but a fetch -- so when a fetch fails it still holds the commit
  HEAD is already on, the two match, and a stale clone is reported current. The
  check written to catch a stale checkout could not see the case that produces
  one (#177). Asking the remote is the fix; this table is what to do with the
  answer, including when there is no answer.
#>

# Verdict states. 'unverifiable' is the one this file exists for: every local
# check passed and currency simply could not be established, which is neither a
# pass nor a failure and must not be filed as either.
Set-Variable -Name MastCurrencyCurrent      -Value 'current'      -Scope Script -Option ReadOnly -Force
Set-Variable -Name MastCurrencyStale        -Value 'stale'        -Scope Script -Option ReadOnly -Force
Set-Variable -Name MastCurrencyUnverifiable -Value 'unverifiable' -Scope Script -Option ReadOnly -Force
Set-Variable -Name MastCurrencyUnverified   -Value 'unverified'   -Scope Script -Option ReadOnly -Force

function Get-MastCurrencyVerdict {
    <#
    .SYNOPSIS
      Verdict for one clone. Returns an object with State and Message.
    .PARAMETER Dir
      The clone folder name, for the message.
    .PARAMETER HeadSha
      HEAD of the local clone.
    .PARAMETER RemoteSha
      What the remote reports for the tracked branch or tag, or '' / $null when
      the remote could not be reached.
    .PARAMETER FetchOk
      clone-manifest.json's fetch_ok for this repo: $true, $false, or $null when
      the key or the sidecar is absent. Only consulted when RemoteSha is absent.
    .PARAMETER VerifiedAt
      The sidecar's written_at, so an unverifiable verdict can say HOW OLD the
      last real verification is. A caveat without an age is a shrug.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Dir,
        [string] $HeadSha,
        [string] $RemoteSha,
        [object] $FetchOk,
        [string] $VerifiedAt
    )

    if ($RemoteSha) {
        if ($HeadSha -eq $RemoteSha) {
            return [pscustomobject]@{
                State   = $script:MastCurrencyCurrent
                Message = ("{0}: current at {1} (origin agrees)" -f $Dir, $HeadSha)
            }
        }
        return [pscustomobject]@{
            State   = $script:MastCurrencyStale
            Message = ("{0} is behind its remote: HEAD={1} origin={2}" -f $Dir, $HeadSha, $RemoteSha)
        }
    }

    # Remote unreachable. The sidecar is the only remaining evidence, and it
    # speaks about a past moment, never about now.
    if ($FetchOk -eq $true) {
        ${age} = $VerifiedAt
        if (-not ${age}) { ${age} = 'an unrecorded time' }
        return [pscustomobject]@{
            State   = $script:MastCurrencyUnverifiable
            Message = ("{0}: CANNOT REACH ORIGIN -- HEAD={1} was verified against origin at {2} and has not been checked since. This is not a currency check." -f $Dir, $HeadSha, ${age})
        }
    }

    # fetch_ok false, or absent entirely: nothing ever confirmed this checkout
    # against the remote. That is the #175 state, and it is a failure.
    ${why} = 'the last provisioning run could not verify it either (fetch_ok=false)'
    if ($null -eq $FetchOk) { ${why} = 'and no fetch_ok in clone-manifest.json, so nothing has ever verified it' }
    return [pscustomobject]@{
        State   = $script:MastCurrencyUnverified
        Message = ("{0}: cannot reach origin {1}; HEAD={2} is unverified" -f $Dir, ${why}, $HeadSha)
    }
}

function Get-MastVerifyExitCode {
    <#
    .SYNOPSIS
      Exit code for a verify run: 0 clean, 1 real problems, 2 clean-but-unverifiable.
    .DESCRIPTION
      2 is a THIRD state, not a severity between 0 and 1. It means every check
      that could run passed and at least one could not run, so the caller must
      not fold it into either. Failures win over unverifiable: a run with both
      has something concretely wrong with it, and that is the actionable half.
    #>
    [CmdletBinding()]
    param(
        [int] $IssueCount = 0,
        [int] $UnverifiableCount = 0
    )
    if ($IssueCount -gt 0) { return 1 }
    if ($UnverifiableCount -gt 0) { return 2 }
    return 0
}
