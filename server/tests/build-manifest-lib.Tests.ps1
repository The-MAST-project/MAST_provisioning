# Unit tests for build/build-manifest-lib.ps1 (Get-PayloadHash,
# Get-ModuleContentHash) -- the per-module tracking Stage 1 hash boundary:
# determinism, module isolation, command/version sensitivity, -TestMode
# optional-payload skips.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\build-manifest-lib.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\..\build\build-manifest-lib.ps1')

$root  = Join-Path $env:TEMP ("mast-manifestlib-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$provA = Join-Path $root 'providers\alpha'
$provB = Join-Path $root 'providers\beta'
New-Item -ItemType Directory -Force -Path (Join-Path $provA 'assets'), $provB | Out-Null
Set-Content -LiteralPath (Join-Path $provA 'provide-alpha.ps1')   -Value 'Write-Host alpha' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $provA 'assets\payload.bin')  -Value ('p' * 64) -NoNewline -Encoding Ascii
Set-Content -LiteralPath (Join-Path $provB 'provide-beta.ps1')    -Value 'Write-Host beta' -Encoding Ascii

$alphaFiles = @('provide-alpha.ps1', 'assets/payload.bin')
$alphaCmds  = @('powershell.exe -File ".\provide-alpha.ps1" -Site neot-smadar',
                'powershell.exe -File ".\verify-alpha.ps1"')

function Get-AlphaHash {
    param([string[]]$Files = $alphaFiles, [string[]]$Cmds = $alphaCmds, [string]$Version = '1.0')
    Get-ModuleContentHash -ProviderDir $provA -CommandFiles $Files -Commands $Cmds -Version $Version
}
function Get-BetaHash {
    Get-ModuleContentHash -ProviderDir $provB -CommandFiles @('provide-beta.ps1') `
        -Commands @('powershell.exe -File ".\provide-beta.ps1"') -Version '2.0'
}

Describe 'Get-ModuleContentHash' {
    It 'is deterministic for identical inputs' {
        Get-AlphaHash | Should Be (Get-AlphaHash)
    }
    It 'does not depend on commandfile declaration order' {
        $reversed = @($alphaFiles[1], $alphaFiles[0])
        Get-AlphaHash -Files $reversed | Should Be (Get-AlphaHash)
    }
    It 'normalizes backslash commandfile paths to forward slashes' {
        Get-AlphaHash -Files @('provide-alpha.ps1', 'assets\payload.bin') | Should Be (Get-AlphaHash)
    }
    It 'changes when a commandfile byte changes, and only for that module' {
        $alphaBefore = Get-AlphaHash
        $betaBefore  = Get-BetaHash
        Set-Content -LiteralPath (Join-Path $provA 'assets\payload.bin') -Value ('q' * 64) -NoNewline -Encoding Ascii
        Get-AlphaHash | Should Not Be $alphaBefore
        Get-BetaHash  | Should Be $betaBefore
        Set-Content -LiteralPath (Join-Path $provA 'assets\payload.bin') -Value ('p' * 64) -NoNewline -Encoding Ascii
        Get-AlphaHash | Should Be $alphaBefore
    }
    It 'changes when a resolved command arg changes (the FastApiUrl/-Site class of drift)' {
        $tweaked = @($alphaCmds[0] -replace 'neot-smadar', 'other-site') + $alphaCmds[1]
        Get-AlphaHash -Cmds $tweaked | Should Not Be (Get-AlphaHash)
    }
    It 'changes when the command order changes' {
        Get-AlphaHash -Cmds @($alphaCmds[1], $alphaCmds[0]) | Should Not Be (Get-AlphaHash)
    }
    It 'changes when the version changes' {
        Get-AlphaHash -Version '1.1' | Should Not Be (Get-AlphaHash)
    }
    It 'skips a missing optional commandfile without crashing (-TestMode payloads)' {
        $withMissing = Get-AlphaHash -Files ($alphaFiles + 'assets/astrometry.tgz')
        $withMissing | Should Be (Get-AlphaHash)
    }
    It 'accepts a module with no commandfiles' {
        $h = Get-ModuleContentHash -ProviderDir $provB -CommandFiles @() -Commands @('cmd /c echo hi') -Version '0.1'
        $h | Should Match '^[0-9a-f]{64}$'
    }
}

$stage = Join-Path $root 'staging'
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'sub') | Out-Null
Set-Content -LiteralPath (Join-Path $stage 'a.txt')     -Value 'aaa' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $stage 'sub\b.txt') -Value 'bbb' -Encoding Ascii

Describe 'Get-PayloadHash' {
    It 'is deterministic' {
        Get-PayloadHash -StagingDir $stage | Should Be (Get-PayloadHash -StagingDir $stage)
    }
    It 'excludes build-manifest.json from the hash' {
        $before = Get-PayloadHash -StagingDir $stage
        Set-Content -LiteralPath (Join-Path $stage 'build-manifest.json') -Value '{"x":1}' -Encoding Ascii
        Get-PayloadHash -StagingDir $stage | Should Be $before
    }
    It 'changes when a staged file changes' {
        $before = Get-PayloadHash -StagingDir $stage
        Set-Content -LiteralPath (Join-Path $stage 'sub\b.txt') -Value 'BBB' -Encoding Ascii
        Get-PayloadHash -StagingDir $stage | Should Not Be $before
    }
}

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
