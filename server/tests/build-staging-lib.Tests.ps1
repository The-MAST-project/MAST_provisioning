# Unit tests for build/build-staging-lib.ps1 -- the 'repofiles' staging key that
# lets a module declare a file living outside its provider dir (tools/mast-clone.ps1
# for the 'mast' module) without forking it into the provider tree.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\build-staging-lib.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\..\build\build-staging-lib.ps1')

$root = Join-Path $env:TEMP ("mast-repofiles-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null
# $env:TEMP can be an 8.3 SHORT path -- GitHub's windows-latest runner reports
# C:\Users\RUNNER~1\AppData\Local\Temp, where the account is 'runneradmin'.
# Resolve-MastRepoFile returns the long form, so building the expected paths
# straight from $env:TEMP compared 'RUNNER~1' against 'runneradmin' and failed by
# exactly three characters. Normalise the root once, so every expectation in this
# file is spelled the way the filesystem spells it.
$root = (Get-Item -LiteralPath $root).FullName
$tools = Join-Path $root 'tools'
$outside = Join-Path $root '..' | ForEach-Object { [System.IO.Path]::GetFullPath($_) }
New-Item -ItemType Directory -Force -Path $tools | Out-Null
Set-Content -LiteralPath (Join-Path $tools 'mast-clone.ps1')  -Value 'clone' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $tools 'mast-repos.tsv')  -Value "dir`trepo" -Encoding Ascii
# A file outside the repo top, used to prove the containment check bites.
$stray = Join-Path $outside ("mast-stray-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
Set-Content -LiteralPath $stray -Value 'stray' -Encoding Ascii

Describe 'Resolve-MastRepoFile' {
    It 'resolves a repo-relative path to its absolute location' {
        $r = Resolve-MastRepoFile -RepoTop $root -RelativePath 'tools/mast-clone.ps1'
        $r | Should Be (Join-Path $tools 'mast-clone.ps1')
    }
    It 'accepts backslash separators (module.json is authored on Windows)' {
        $r = Resolve-MastRepoFile -RepoTop $root -RelativePath 'tools\mast-repos.tsv'
        $r | Should Be (Join-Path $tools 'mast-repos.tsv')
    }
    It 'rejects an absolute path' {
        { Resolve-MastRepoFile -RepoTop $root -RelativePath (Join-Path $tools 'mast-clone.ps1') } |
            Should Throw
    }
    It 'rejects a .. segment even when the target exists' {
        # This is the containment check doing its job: the file is real, but
        # reaching it means leaving the repo top.
        $rel = '..\' + (Split-Path $stray -Leaf)
        { Resolve-MastRepoFile -RepoTop $root -RelativePath $rel } | Should Throw
    }
    It 'rejects an empty entry' {
        { Resolve-MastRepoFile -RepoTop $root -RelativePath '  ' } | Should Throw
    }
    It 'fails loudly on a missing file rather than staging nothing' {
        # A typo in module.json must break the build, not silently omit a file
        # the unit-side command then cannot find.
        { Resolve-MastRepoFile -RepoTop $root -RelativePath 'tools/mast-clonee.ps1' } | Should Throw
    }
    It 'names the module in the error so a build failure points at the manifest' {
        $msg = ''
        try { Resolve-MastRepoFile -RepoTop $root -RelativePath 'tools/nope.ps1' -ModuleName 'mast' }
        catch { $msg = $_.Exception.Message }
        $msg | Should Match 'mast'
    }
    It 'rejects a directory (repofiles are files, staged by leaf name)' {
        { Resolve-MastRepoFile -RepoTop $root -RelativePath 'tools' } | Should Throw
    }
}

Describe 'Get-MastRepoFileStagingPath' {
    It 'flattens to the staging root by leaf name' {
        # Flattened like assets/*: the unit-side executor runs each command with
        # the staging root as its working directory.
        $p = Get-MastRepoFileStagingPath -StagingDir 'C:\stage' -RelativePath 'tools/mast-clone.ps1'
        $p | Should Be 'C:\stage\mast-clone.ps1'
    }
    It 'flattens a backslash path the same way' {
        $p = Get-MastRepoFileStagingPath -StagingDir 'C:\stage' -RelativePath 'tools\mast-repos.tsv'
        $p | Should Be 'C:\stage\mast-repos.tsv'
    }
}

Describe 'Get-MastModuleRepoFiles' {
    It 'returns an empty array when the key is absent (every module today)' {
        $mf = '{ "name": "x", "version": "1" }' | ConvertFrom-Json
        @(Get-MastModuleRepoFiles -Manifest $mf).Count | Should Be 0
    }
    It 'returns an empty array when the key is present but empty' {
        $mf = '{ "name": "x", "repofiles": [] }' | ConvertFrom-Json
        @(Get-MastModuleRepoFiles -Manifest $mf).Count | Should Be 0
    }
    It 'returns the declared entries in order' {
        $mf = '{ "name": "mast", "repofiles": ["tools/mast-clone.ps1", "tools/mast-repos.tsv"] }' |
                ConvertFrom-Json
        $r = @(Get-MastModuleRepoFiles -Manifest $mf)
        $r.Count | Should Be 2
        $r[0] | Should Be 'tools/mast-clone.ps1'
        $r[1] | Should Be 'tools/mast-repos.tsv'
    }
    It 'drops blank entries rather than passing them to the resolver' {
        $mf = '{ "name": "mast", "repofiles": ["tools/mast-clone.ps1", ""] }' | ConvertFrom-Json
        @(Get-MastModuleRepoFiles -Manifest $mf).Count | Should Be 1
    }
}

Remove-Item -LiteralPath $stray -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
