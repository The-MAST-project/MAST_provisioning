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

# Repo-top shared tooling, the 'repofiles' shape (tools/mast-clone.ps1 for the
# real mast module).
$tools = Join-Path $root 'tools'
New-Item -ItemType Directory -Force -Path $tools | Out-Null
Set-Content -LiteralPath (Join-Path $tools 'mast-clone.ps1') -Value 'clone v1' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $tools 'mast-repos.tsv') -Value "dir`trepo" -Encoding Ascii

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

Describe 'Get-ModuleContentHash -- repofiles (shared repo-top tooling)' {
    # A module that runs tools/mast-clone.ps1 must drift when that script
    # changes. Nothing under its provider dir moves, so without repofiles in the
    # hash boundary the change is visible only in the aggregate payload_hash --
    # "something changed", not "the mast module changed" -- and targeted updates
    # would never select it.
    function Get-WithRepoFiles {
        param([string[]]$RepoFiles = @('tools/mast-clone.ps1', 'tools/mast-repos.tsv'))
        Get-ModuleContentHash -ProviderDir $provA -CommandFiles $alphaFiles -Commands $alphaCmds `
            -Version '1.0' -RepoTop $root -RepoFiles $RepoFiles
    }

    It 'changes the hash versus the same module with no repofiles' {
        Get-WithRepoFiles | Should Not Be (Get-AlphaHash)
    }
    It 'is deterministic' {
        Get-WithRepoFiles | Should Be (Get-WithRepoFiles)
    }
    It 'does not depend on declaration order' {
        Get-WithRepoFiles -RepoFiles @('tools/mast-repos.tsv', 'tools/mast-clone.ps1') |
            Should Be (Get-WithRepoFiles)
    }
    It 'changes when the shared tool changes, though the provider dir did not' {
        $before = Get-WithRepoFiles
        Set-Content -LiteralPath (Join-Path $tools 'mast-clone.ps1') -Value 'clone v2' -Encoding Ascii
        Get-WithRepoFiles | Should Not Be $before
        Set-Content -LiteralPath (Join-Path $tools 'mast-clone.ps1') -Value 'clone v1' -Encoding Ascii
    }
    It 'leaves a module that declares no repofiles unchanged' {
        # Adding the parameter must not rotate every other module's hash.
        Get-ModuleContentHash -ProviderDir $provA -CommandFiles $alphaFiles -Commands $alphaCmds `
            -Version '1.0' -RepoTop $root -RepoFiles @() | Should Be (Get-AlphaHash)
    }
    It 'throws on a missing repofile rather than hashing a gap' {
        # Unlike a commandfile, this can never be a -TestMode optional payload:
        # the staging pass has already thrown for it.
        { Get-WithRepoFiles -RepoFiles @('tools/not-there.ps1') } | Should Throw
    }
    It 'throws when repofiles are given without a repo top' {
        { Get-ModuleContentHash -ProviderDir $provA -RepoFiles @('tools/mast-clone.ps1') } |
            Should Throw
    }
}

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue

Describe 'Get-MastStagedFiles' {
    # payload_hash covered 290 of 543 files because Get-ChildItem -Recurse does not
    # descend reparse points, and build-mast stages mast-indexes and
    # cygwin-pkg-cache as junctions when elevated -- 11 GB of a 14.9 GB payload,
    # including the 9.9 GB index seed, outside the aggregate "anything changed"
    # gate (#203). This is the one enumeration everything now shares.
    $root = Join-Path $env:TEMP ("mast-staged-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $outside = Join-Path $env:TEMP ("mast-outside-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $root, $outside, (Join-Path $root 'real') | Out-Null
    $root = (Get-Item -LiteralPath $root).FullName
    $outside = (Get-Item -LiteralPath $outside).FullName
    Set-Content -LiteralPath (Join-Path $root 'top.txt')          -Value 'aaa'  -Encoding Ascii -NoNewline
    Set-Content -LiteralPath (Join-Path $root 'real\nested.txt')  -Value 'bbbb' -Encoding Ascii -NoNewline
    Set-Content -LiteralPath (Join-Path $outside 'vendored.bin')  -Value 'ccccc' -Encoding Ascii -NoNewline
    cmd /c mklink /J "$root\linked" "$outside" | Out-Null

    It 'descends a junction, which Get-ChildItem -Recurse does not' {
        $viaGci = @(Get-ChildItem -Path $root -File -Recurse -ErrorAction SilentlyContinue).Count
        $viaWalk = @(Get-MastStagedFiles -StagingDir $root).Count
        $viaGci  | Should Be 2
        $viaWalk | Should Be 3
    }
    It 'reports paths relative to the staging root, with forward slashes' {
        $paths = @(Get-MastStagedFiles -StagingDir $root | ForEach-Object { $_.RelativePath }) | Sort-Object
        ($paths -join ',') | Should Be 'linked/vendored.bin,real/nested.txt,top.txt'
    }
    It 'reports the size of what a junction points at' {
        $e = Get-MastStagedFiles -StagingDir $root | Where-Object { $_.RelativePath -eq 'linked/vendored.bin' }
        $e.Length | Should Be 5
    }
    It 'is stable in order, so the rolling hash is deterministic' {
        $a = (Get-MastStagedFiles -StagingDir $root | ForEach-Object { $_.RelativePath }) -join ','
        $b = (Get-MastStagedFiles -StagingDir $root | ForEach-Object { $_.RelativePath }) -join ','
        $a | Should Be $b
    }
    It 'returns nothing for a path that does not exist' {
        @(Get-MastStagedFiles -StagingDir (Join-Path $root 'absent')).Count | Should Be 0
    }
}

Describe 'Get-MastPayloadManifest' {
    $root = Join-Path $env:TEMP ("mast-manifest-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $root = (Get-Item -LiteralPath $root).FullName
    Set-Content -LiteralPath (Join-Path $root 'a.txt') -Value 'hello' -Encoding Ascii -NoNewline

    It 'lists every file with its size and content hash' {
        # @() around the call, not $m[0]: PowerShell unrolls a single-element
        # array on return, so $m would be the entry itself and $m[0] a key
        # lookup. Every caller wraps for the same reason.
        $m = @(Get-MastPayloadManifest -StagingDir $root)
        $m.Count     | Should Be 1
        $m[0].path   | Should Be 'a.txt'
        $m[0].size   | Should Be 5
        # sha256("hello")
        $m[0].sha256 | Should Be '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
    }
    It 'agrees with the hash input, so the two cannot describe different payloads' {
        $files = @(Get-MastStagedFiles -StagingDir $root)
        @(Get-MastPayloadManifest -StagingDir $root).Count | Should Be $files.Count
    }
    It 'lists build-manifest.json, which the hash excludes but the payload carries' {
        # The two exclusions are not the same exclusion. Get-PayloadHash omits
        # build-manifest.json because it is generating it; the payload manifest
        # is written after, describes what must reach the unit, and the unit
        # reads build-manifest.json to record what it installed. Omitting it
        # there assembled a 542-file tree against a 543-file payload and
        # mast07's destination check failed short_transfer (#203).
        Set-Content -LiteralPath (Join-Path $root 'build-manifest.json') -Value '{}' -Encoding Ascii -NoNewline
        $paths = @(Get-MastPayloadManifest -StagingDir $root) | ForEach-Object { $_.path }
        ($paths -contains 'build-manifest.json') | Should Be $true
    }
}
