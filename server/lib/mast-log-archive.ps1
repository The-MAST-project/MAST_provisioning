# Provisioning-log lifecycle: per-run archival + retention on the prov server.
# Dot-source from check-and-provision.ps1. ASCII-only, PowerShell 5.1 safe.
#
# The controller already writes each run's controller log under
# C:\MAST\logs\prov\sessions\<run-id>\ (Get-MastProvSessionDir). This module
# adds the two lifecycle pieces item 5 calls for: selecting which old run dirs
# to prune (bounded growth for a host up for weeks-to-years) and running that
# prune. The high-risk decision -- which dirs to delete -- is a pure function so
# it can be unit-tested; the filesystem side is a thin runner over it.

Set-StrictMode -Version Latest

function Get-RunIdTimestamp {
    # A run id is "run-yyyyMMdd-HHmmss" (see check-and-provision.ps1). Return the
    # embedded "yyyyMMdd-HHmmss" (which sorts lexically == chronologically) or
    # $null if the name does not conform -- a non-conforming dir is left alone.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId)
    if ($RunId -match '^run-(\d{8}-\d{6})$') { return $Matches[1] }
    return $null
}

function Select-MastProvPrunableRuns {
    # Keep-newest-N retention: given all run-id dir names, return those to prune.
    # The newest $Retain conforming names are always kept (this is the hard
    # ceiling that bounds growth); everything ranked beyond them is returned for
    # pruning. Non-conforming names (unknown provenance) are never pruned.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RunIds,
        [Parameter(Mandatory)][int]$Retain
    )
    if ($Retain -lt 1) { throw "Retain must be >= 1 (got $Retain)." }
    $conforming = @($RunIds | Where-Object { $null -ne (Get-RunIdTimestamp $_) })
    if ($conforming.Count -le $Retain) { return @() }
    $sorted = @($conforming | Sort-Object -Property @{ Expression = { Get-RunIdTimestamp $_ } } -Descending)
    return @($sorted[$Retain..($sorted.Count - 1)])
}

function Invoke-MastProvRetention {
    # List the run-session dirs under $SessionsRoot, decide which to prune via
    # Select-MastProvPrunableRuns, and remove them. Returns the run ids removed.
    # $Logger is an optional scriptblock (param($message)) used for warnings.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionsRoot,
        [Parameter(Mandatory)][int]$Retain,
        [scriptblock]$Logger
    )
    if (-not (Test-Path $SessionsRoot)) { return @() }
    $names = @(Get-ChildItem -Path $SessionsRoot -Directory -ErrorAction SilentlyContinue |
               ForEach-Object { $_.Name })
    $prune = Select-MastProvPrunableRuns -RunIds $names -Retain $Retain
    $removed = @()
    foreach ($p in $prune) {
        $full = Join-Path $SessionsRoot $p
        try {
            Remove-Item -Path $full -Recurse -Force -ErrorAction Stop
            $removed += $p
        } catch {
            if ($Logger) { & $Logger "prune failed dir=$p err=$($_.Exception.Message)" }
        }
    }
    return $removed
}
