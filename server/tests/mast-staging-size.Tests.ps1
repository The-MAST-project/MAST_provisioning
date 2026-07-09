# Integration test for server/lib/mast-staging-size.ps1. Builds a REAL directory
# junction (mklink /J -- no elevation needed) so the junction-traversal behavior
# is exercised on the same Windows PowerShell 5.1 the driver runs under.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\mast-staging-size.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\lib\mast-staging-size.ps1')

$root       = Join-Path $env:TEMP ("mast-stagesize-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$stage      = Join-Path $root 'staging'
$indexStore = Join-Path $root 'index-store'
New-Item -ItemType Directory -Force -Path $stage, $indexStore, (Join-Path $stage 'sub') | Out-Null
Set-Content -LiteralPath (Join-Path $stage 'a.bin')      -Value ('x' * 100) -NoNewline -Encoding Ascii  # 100 B
Set-Content -LiteralPath (Join-Path $stage 'sub\b.bin')  -Value ('y' * 200) -NoNewline -Encoding Ascii  # 200 B
Set-Content -LiteralPath (Join-Path $indexStore 'idx.bin') -Value ('z' * 500) -NoNewline -Encoding Ascii  # 500 B
# Junction inside staging -> the out-of-tree index store (the mast-indexes shape).
$jPath = Join-Path $stage 'mast-indexes'
& cmd /c ('mklink /J "{0}" "{1}"' -f $jPath, $indexStore) | Out-Null

Describe 'Get-StagingPayloadSize' {
    It 'counts real files PLUS content reached only through the junction' {
        $r = Get-StagingPayloadSize -Path $stage
        $r.Bytes | Should Be 800   # 100 + 200 + 500 (through mast-indexes)
        $r.Files | Should Be 3
    }
    It 'a naive Get-ChildItem -Recurse undercounts (the bug this fixes / no double-count)' {
        $naive = @(Get-ChildItem -LiteralPath $stage -File -Recurse -Force -ErrorAction SilentlyContinue)
        # If this is 300, the junction is NOT descended naively (production case) and
        # the helper's +500 is correct. If it were 800, the helper would double-count
        # and the test above would fail -- so this pins the assumption.
        ($naive | Measure-Object -Sum -Property Length).Sum | Should Be 300
    }
}

# Cleanup: drop the junction LINK first (rmdir removes the reparse point, not its
# target), then the tree -- so Remove-Item cannot delete through the junction.
& cmd /c ('rmdir "{0}"' -f $jPath) 2>$null | Out-Null
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
