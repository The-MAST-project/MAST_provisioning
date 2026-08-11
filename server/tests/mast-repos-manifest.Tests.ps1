# Unit tests for the mast-repos.tsv manifest contract -- specifically the optional
# 5th 'rev' column added for #75.
#
# The parse lives in both tools/mast-clone.ps1 and tools/mast-clone.sh, which share
# the manifest and must not diverge. This exercises the ps1 shape of it directly:
# the scripts' own parse is four lines, so a test that re-implements it would prove
# nothing -- instead this asserts the CONTRACT the manifest has to satisfy, which is
# what a hand-edit is likely to break.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\mast-repos-manifest.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifest = Join-Path $here '..\..\tools\mast-repos.tsv'

# The same parse both clone scripts perform, kept deliberately literal.
function Read-ManifestRows {
    param([Parameter(Mandatory)][string]$Path)
    $rows = @()
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0) { continue }
        if ($trimmed.StartsWith('#')) { continue }
        $parts = $line -split "`t"
        if ($parts.Count -lt 4) { continue }
        $rev = ''
        if ($parts.Count -ge 5) { $rev = $parts[4].Trim() }
        $rows += [pscustomobject]@{
            Dir = $parts[0].Trim(); Repo = $parts[1].Trim()
            Roles = ($parts[2].Trim() -split ','); Branch = $parts[3].Trim(); Rev = $rev
        }
    }
    return $rows
}

Describe 'mast-repos.tsv' {
    It 'parses and yields rows' {
        $rows = Read-ManifestRows -Path $manifest
        @($rows).Count -gt 0 | Should Be $true
    }
    It "names 'common' exactly, because MAST_common's root IS the package" {
        $rows = Read-ManifestRows -Path $manifest
        @($rows | Where-Object { $_.Dir -eq 'common' }).Count | Should Be 1
    }
    It 'gives every row an explicit branch (never the remote default)' {
        foreach ($r in (Read-ManifestRows -Path $manifest)) {
            $r.Branch | Should Not BeNullOrEmpty
        }
    }
    It 'still carries the pinned uv version directive' {
        (Get-Content -LiteralPath $manifest | Where-Object { $_ -match '^#!uv-version\s+\S+' }).Count | Should Be 1
    }
    It 'tolerates a 4-column row -- rev is optional, so an unpinned manifest parses' {
        $tmp = Join-Path $env:TEMP ("mast-repos-4col-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.tsv')
        [IO.File]::WriteAllLines($tmp, @("# dir`trepo`troles`tbranch", "common`tMAST_common`tunit`tmaster"))
        try {
            $rows = Read-ManifestRows -Path $tmp
            @($rows).Count | Should Be 1
            $rows[0].Rev   | Should Be ''
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    It 'reads a 5th column as the pinned rev' {
        $tmp = Join-Path $env:TEMP ("mast-repos-5col-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.tsv')
        [IO.File]::WriteAllLines($tmp, @("common`tMAST_common`tunit`tmaster`tv1.2.3"))
        try {
            $rows = Read-ManifestRows -Path $tmp
            $rows[0].Rev | Should Be 'v1.2.3'
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    It 'treats a trailing tab with nothing after it as unpinned, not as a rev' {
        # This is the shape a hand-edit produces when adding the column to only
        # some rows, and it must mean "track the branch" rather than an empty pin.
        $tmp = Join-Path $env:TEMP ("mast-repos-empty-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.tsv')
        [IO.File]::WriteAllLines($tmp, @("common`tMAST_common`tunit`tmaster`t"))
        try {
            (Read-ManifestRows -Path $tmp)[0].Rev | Should Be ''
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}
