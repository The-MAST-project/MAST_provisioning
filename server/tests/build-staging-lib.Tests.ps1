# Unit tests for build/build-staging-lib.ps1 -- two subjects:
#   - the 'repofiles' staging key that lets a module declare a file living
#     outside its provider dir (tools/mast-clone.ps1 for the 'mast' module)
#     without forking it into the provider tree;
#   - the wheel-tag check that keeps the jupyter wheelhouse and the interpreter
#     the 'python' provider pins from drifting apart (#180).
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

Describe 'Get-MastWheelInterpreterMismatches' {
    # The tree as it stands. Asserting the count is non-zero first is what stops
    # this passing vacuously if the wheelhouse ever moves or empties.
    It 'finds nothing wrong with the wheelhouse in the repo against the pinned 3.12.2' {
        $wheelDir = Join-Path $here '..\..\server\providers\jupyter\assets\wheels'
        $names = @(Get-ChildItem -LiteralPath $wheelDir -Filter '*.whl' -File | ForEach-Object { $_.Name })
        ($names.Count -gt 0) | Should Be $true
        @(Get-MastWheelInterpreterMismatches -PythonVersion '3.12.2' -WheelNames $names).Count | Should Be 0
    }
    It 'accepts a version-locked wheel built for the target interpreter' {
        @(Get-MastWheelInterpreterMismatches -PythonVersion '3.12.2' `
            -WheelNames @('cffi-2.1.1-cp312-cp312-win_amd64.whl')).Count | Should Be 0
    }
    It 'rejects a version-locked wheel when the interpreter is bumped' {
        # The #180 scenario: the edit is in the python provider, the breakage is here.
        $r = @(Get-MastWheelInterpreterMismatches -PythonVersion '3.13.0' `
                 -WheelNames @('cffi-2.1.1-cp312-cp312-win_amd64.whl'))
        $r.Count | Should Be 1
        $r[0] | Should Match 'built for cp312, needs cp313'
    }
    It 'accepts a stable-ABI wheel whose minimum is older than the target' {
        @(Get-MastWheelInterpreterMismatches -PythonVersion '3.12.2' `
            -WheelNames @('pyerfa-2.0.1.5-cp39-abi3-win_amd64.whl')).Count | Should Be 0
    }
    It 'accepts a stable-ABI wheel whose minimum equals the target' {
        @(Get-MastWheelInterpreterMismatches -PythonVersion '3.12.2' `
            -WheelNames @('pyzmq-27.2.0-cp312-abi3-win_amd64.whl')).Count | Should Be 0
    }
    It 'rejects a stable-ABI wheel whose minimum is newer than the target' {
        $r = @(Get-MastWheelInterpreterMismatches -PythonVersion '3.12.2' `
                 -WheelNames @('something-1.0-cp313-abi3-win_amd64.whl'))
        $r.Count | Should Be 1
        $r[0] | Should Match 'minimum cp313 is newer than cp312'
    }
    It 'ignores pure-Python wheels' {
        @(Get-MastWheelInterpreterMismatches -PythonVersion '3.13.0' `
            -WheelNames @('anyio-4.14.2-py3-none-any.whl')).Count | Should Be 0
    }
    It 'ignores a non-CPython python tag' {
        @(Get-MastWheelInterpreterMismatches -PythonVersion '3.12.2' `
            -WheelNames @('greenlet-3.0-pp310-pypy310_pp73-win_amd64.whl')).Count | Should Be 0
    }
    It 'parses a name carrying an optional build tag' {
        # PEP 427 allows name-version-BUILD-pytag-abitag-platform; the tags are
        # read from the end for exactly this reason.
        $r = @(Get-MastWheelInterpreterMismatches -PythonVersion '3.13.0' `
                 -WheelNames @('foo-1.0-1-cp312-cp312-win_amd64.whl'))
        $r.Count | Should Be 1
    }
    It 'ignores a file that is not a wheel' {
        @(Get-MastWheelInterpreterMismatches -PythonVersion '3.12.2' `
            -WheelNames @('requirements.txt')).Count | Should Be 0
    }
    It 'reads the tags off the leaf when handed a path' {
        @(Get-MastWheelInterpreterMismatches -PythonVersion '3.12.2' `
            -WheelNames @('C:\assets\wheels\cffi-2.1.1-cp312-cp312-win_amd64.whl')).Count | Should Be 0
    }
    It 'accepts an empty wheel list (the staging throw owns an empty wheelhouse)' {
        @(Get-MastWheelInterpreterMismatches -PythonVersion '3.12.2' -WheelNames @()).Count | Should Be 0
    }
    It 'throws on a declared version it cannot read a major.minor from' {
        { Get-MastWheelInterpreterMismatches -PythonVersion 'git' -WheelNames @() } | Should Throw
    }
}

Remove-Item -LiteralPath $stray -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue

Describe 'Test-MastCommandFileIsAsset' {
    It 'calls an assets/ entry an asset' {
        Test-MastCommandFileIsAsset -CommandFile 'assets/AscomPlatform700.rc4.4448.exe' | Should Be $true
    }
    It 'accepts backslash separators' {
        Test-MastCommandFileIsAsset -CommandFile 'assets\ImDiskTk-x64.zip' | Should Be $true
    }
    It 'does not call a provider script an asset' {
        # The never-exclude-scripts rule lives here. A verify script that stopped
        # shipping would fail run-verify-only.ps1 on an untargeted module and
        # manufacture tier-2 needs-repair drift.
        Test-MastCommandFileIsAsset -CommandFile 'provide-ascom.ps1' | Should Be $false
        Test-MastCommandFileIsAsset -CommandFile 'verify-jupyter.ps1' | Should Be $false
    }
    It 'does not treat a name merely starting with assets as one' {
        Test-MastCommandFileIsAsset -CommandFile 'assets-readme.txt' | Should Be $false
    }
}

Describe 'Add-MastStagedPayload' {
    It 'records a directory against its module' {
        $m = New-MastStagedPayloadMap
        Add-MastStagedPayload -Map $m -Module 'imdisk' -Dir 'mast-indexes'
        ($m['imdisk'].dirs -join ',')  | Should Be 'mast-indexes'
        ($m['imdisk'].files -join ',') | Should Be ''
    }
    It 'records a file against its module' {
        $m = New-MastStagedPayloadMap
        Add-MastStagedPayload -Map $m -Module 'chrome' -File 'GoogleChromeStandaloneEnterprise64.msi'
        ($m['chrome'].files -join ',') | Should Be 'GoogleChromeStandaloneEnterprise64.msi'
    }
    It 'records one entry against several modules' {
        # full-frame.fits is staged for astrometry OR mast-validation, so both
        # are claimants and either one targeted must keep it in the payload.
        $m = New-MastStagedPayloadMap
        Add-MastStagedPayload -Map $m -Module 'astrometry'      -File 'full-frame.fits'
        Add-MastStagedPayload -Map $m -Module 'mast-validation' -File 'full-frame.fits'
        ($m['astrometry'].files -join ',')      | Should Be 'full-frame.fits'
        ($m['mast-validation'].files -join ',') | Should Be 'full-frame.fits'
    }
    It 'is idempotent for a repeated entry' {
        $m = New-MastStagedPayloadMap
        Add-MastStagedPayload -Map $m -Module 'jupyter' -Dir 'wheels'
        Add-MastStagedPayload -Map $m -Module 'jupyter' -Dir 'wheels'
        @($m['jupyter'].dirs).Count | Should Be 1
    }
    It 'keeps several entries for one module in insertion order' {
        $m = New-MastStagedPayloadMap
        Add-MastStagedPayload -Map $m -Module 'mast' -File 'uv-x86_64-pc-windows-msvc.zip'
        Add-MastStagedPayload -Map $m -Module 'mast' -File 'uv-x86_64-pc-windows-msvc.zip.sha256'
        ($m['mast'].files -join ',') | Should Be 'uv-x86_64-pc-windows-msvc.zip,uv-x86_64-pc-windows-msvc.zip.sha256'
    }
    It 'rejects a nested name' {
        # Staging is flat at the root and the driver turns these names into
        # robocopy exclusions against the staging root, so a source-relative
        # path here would produce an exclusion that matches nothing.
        $m = New-MastStagedPayloadMap
        { Add-MastStagedPayload -Map $m -Module 'ascom' -File 'assets/AscomPlatform700.rc4.4448.exe' } | Should Throw
    }
    It 'rejects an empty module or entry' {
        $m = New-MastStagedPayloadMap
        { Add-MastStagedPayload -Map $m -Module ''      -File 'x.exe' } | Should Throw
        { Add-MastStagedPayload -Map $m -Module 'ascom' -File ''      } | Should Throw
    }
    It 'requires exactly one of -File and -Dir' {
        $m = New-MastStagedPayloadMap
        { Add-MastStagedPayload -Map $m -Module 'ascom' } | Should Throw
        { Add-MastStagedPayload -Map $m -Module 'ascom' -File 'x.exe' -Dir 'sxs' } | Should Throw
    }
}

Describe 'Get-MastStagingRootName' {
    It 'calls a flat commandfile its own root entry' {
        $r = Get-MastStagingRootName -RelativePath 'provide-ascom.ps1'
        $r.Name | Should Be 'provide-ascom.ps1'
        $r.IsDir | Should Be $false
    }
    It 'calls a nested commandfile a root DIRECTORY' {
        # config-bootstrap declares sites/ns.toml, which stages as sites\ns.toml.
        # Recording the leaf would name something that is not at the root and
        # leave sites\ unaccounted -- caught by the completeness check.
        $r = Get-MastStagingRootName -RelativePath 'sites/ns.toml'
        $r.Name | Should Be 'sites'
        $r.IsDir | Should Be $true
    }
    It 'accepts backslash separators' {
        (Get-MastStagingRootName -RelativePath 'sites\wis.toml').Name | Should Be 'sites'
    }
}

Describe 'Add-MastAlwaysStagedPayload' {
    It 'records a file every run needs' {
        $a = New-MastAlwaysPayload
        Add-MastAlwaysStagedPayload -Payload $a -File 'commands.json'
        ($a.files -join ',') | Should Be 'commands.json'
    }
    It 'is idempotent' {
        # Two providers can declare the same verify script leaf; the flatten
        # loop records each one it stages.
        $a = New-MastAlwaysPayload
        Add-MastAlwaysStagedPayload -Payload $a -File 'mast-log.ps1'
        Add-MastAlwaysStagedPayload -Payload $a -File 'mast-log.ps1'
        @($a.files).Count | Should Be 1
    }
    It 'rejects a nested name and a missing name' {
        $a = New-MastAlwaysPayload
        { Add-MastAlwaysStagedPayload -Payload $a -File 'assets/x.exe' } | Should Throw
        { Add-MastAlwaysStagedPayload -Payload $a } | Should Throw
        { Add-MastAlwaysStagedPayload -Payload $a -File 'x' -Dir 'y' } | Should Throw
    }
}

Describe 'Get-MastUnattributedStagedEntries' {
    $stage = Join-Path $env:TEMP ("mast-unattributed-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $stage = (Get-Item -LiteralPath $stage).FullName
    Set-Content -LiteralPath (Join-Path $stage 'claimed.exe') -Value ('x' * 100) -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $stage 'commands.json') -Value ('y' * 10) -Encoding Ascii
    $big = Join-Path $stage 'vendor-blob'
    New-Item -ItemType Directory -Force -Path $big | Out-Null
    Set-Content -LiteralPath (Join-Path $big 'data.bin') -Value ('z' * 500) -Encoding Ascii

    $map = New-MastStagedPayloadMap
    Add-MastStagedPayload -Map $map -Module 'someprovider' -File 'claimed.exe'
    $always = New-MastAlwaysPayload
    Add-MastAlwaysStagedPayload -Payload $always -File 'commands.json'

    It 'omits an entry a module claims' {
        $r = Get-MastUnattributedStagedEntries -StagingDir $stage -Map $map -Always $always
        @($r | Where-Object { $_.Name -eq 'claimed.exe' }).Count | Should Be 0
    }
    It 'omits an entry declared always-ship' {
        $r = Get-MastUnattributedStagedEntries -StagingDir $stage -Map $map -Always $always
        @($r | Where-Object { $_.Name -eq 'commands.json' }).Count | Should Be 0
    }
    It 'reports an entry declared by neither, sized by its contents' {
        # The shape that hid 2.1 GB of PlateSolve3 catalog. The build now throws
        # on this rather than shipping a payload it cannot describe.
        $r = Get-MastUnattributedStagedEntries -StagingDir $stage -Map $map -Always $always
        @($r).Count | Should Be 1
        $r[0].Name | Should Be 'vendor-blob'
        $r[0].Bytes | Should BeGreaterThan 400
    }
    It 'reports everything when nothing is declared' {
        $r = Get-MastUnattributedStagedEntries -StagingDir $stage -Map (New-MastStagedPayloadMap) -Always (New-MastAlwaysPayload)
        @($r).Count | Should Be 3
    }
}

Describe 'Get-MastReposManifestVersion' {
    $top = Join-Path $env:TEMP ("mast-reposver-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path (Join-Path $top 'tools') | Out-Null
    $top = (Get-Item -LiteralPath $top).FullName
    $manifest = Join-Path $top 'tools\mast-repos.tsv'
    Set-Content -LiteralPath $manifest -Value "common`tMAST_common`tunit`tmaster`tdeadbeef" -Encoding Ascii

    It 'reports an identity derived from the manifest' {
        (Get-MastReposManifestVersion -RepoTop $top) | Should Match '^repos-[0-9a-f]{12}$'
    }
    It 'is stable while the manifest is' {
        (Get-MastReposManifestVersion -RepoTop $top) | Should Be (Get-MastReposManifestVersion -RepoTop $top)
    }
    It 'moves when a pin moves' {
        # The whole point: the mast module's reported version tracks which MAST
        # revisions a unit is meant to be on, not which commit of THIS repo built
        # the payload.
        $before = Get-MastReposManifestVersion -RepoTop $top
        Set-Content -LiteralPath $manifest -Value "common`tMAST_common`tunit`tmaster`tcafebabe" -Encoding Ascii
        (Get-MastReposManifestVersion -RepoTop $top) | Should Not Be $before
    }
    It 'throws when the manifest is missing rather than versioning the module as nothing' {
        { Get-MastReposManifestVersion -RepoTop (Join-Path $top 'absent') } | Should Throw
    }
}

Describe 'Resolve-MastAssetSource' {
    # Where a provider's asset comes from once the binaries leave git-LFS (#48).
    #
    # They cannot simply become gitignored files in the repo tree: builds run from
    # git worktrees on the provisioning server, and a fresh worktree would hold
    # none of them -- 2.3 GB per worktree is not a fix. So they move to one
    # machine-wide cache, the same shape the five existing vendor inputs already
    # use at C:\MAST\, which is what #48 asks for: one store every vendored binary
    # goes through.
    #
    # The repo copy WINS while it exists. That makes landing this a no-op: nothing
    # resolves differently until the untracking step removes the repo copies, so
    # the risky change and the behaviour change are separated.

    $root = Join-Path $env:TEMP ("mast-assetsrc-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $repoAsset  = Join-Path $root 'providers\chrome\assets'
    $cacheAsset = Join-Path $root 'cache\server\providers\chrome\assets'
    New-Item -ItemType Directory -Force -Path $repoAsset, $cacheAsset | Out-Null
    $providers = Join-Path $root 'providers'
    $cache     = Join-Path $root 'cache'

    It 'prefers the repo copy while one exists, so landing this changes nothing' {
        Set-Content -LiteralPath (Join-Path $repoAsset 'chrome.msi')  -Value 'repo'  -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $cacheAsset 'chrome.msi') -Value 'cache' -Encoding Ascii
        $p = Resolve-MastAssetSource -ProvidersRoot $providers -Module 'chrome' `
                -CommandFile 'assets/chrome.msi' -AssetCacheRoot $cache
        (Get-Content -LiteralPath $p -Raw).Trim() | Should Be 'repo'
    }

    It 'falls back to the cache once the repo copy is gone' {
        Remove-Item -LiteralPath (Join-Path $repoAsset 'chrome.msi') -Force
        $p = Resolve-MastAssetSource -ProvidersRoot $providers -Module 'chrome' `
                -CommandFile 'assets/chrome.msi' -AssetCacheRoot $cache
        (Get-Content -LiteralPath $p -Raw).Trim() | Should Be 'cache'
    }

    It 'returns the repo path when neither exists, so the caller reports the familiar location' {
        # build-mast throws "missing CommandFile: <path>" on absence. Naming the
        # cache there would send someone to a directory that is only a cache.
        Remove-Item -LiteralPath (Join-Path $cacheAsset 'chrome.msi') -Force
        $p = Resolve-MastAssetSource -ProvidersRoot $providers -Module 'chrome' `
                -CommandFile 'assets/chrome.msi' -AssetCacheRoot $cache
        $p | Should Be (Join-Path (Join-Path $providers 'chrome') 'assets/chrome.msi')
    }

    It 'never redirects a script, only an asset' {
        # Scripts are the repo's own code and are never cached; only assets/ is.
        Set-Content -LiteralPath (Join-Path (Join-Path $providers 'chrome') 'provide-chrome.ps1') -Value 'x' -Encoding Ascii
        $p = Resolve-MastAssetSource -ProvidersRoot $providers -Module 'chrome' `
                -CommandFile 'provide-chrome.ps1' -AssetCacheRoot $cache
        $p | Should Be (Join-Path (Join-Path $providers 'chrome') 'provide-chrome.ps1')
    }

    It 'has no cache root configured: behaves exactly as before' {
        $p = Resolve-MastAssetSource -ProvidersRoot $providers -Module 'chrome' `
                -CommandFile 'assets/chrome.msi' -AssetCacheRoot ''
        $p | Should Be (Join-Path (Join-Path $providers 'chrome') 'assets/chrome.msi')
    }
}

Describe 'Get-MastAssetTreeEntries' {
    # A directory-shaped asset resolves per file, not per tree, because some of
    # these directories are mixed: assets\sxs holds three vendored .cab files
    # beside a README and a fetch script that are ordinary tracked code. "Which
    # root does this directory come from" has no answer; "which root does this
    # file come from" does.

    $root  = Join-Path $env:TEMP ("mast-assettree-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $repo  = Join-Path $root 'providers\ascom\assets\sxs\19044'
    $cache = Join-Path $root 'cache\server\providers\ascom\assets\sxs\19044'
    New-Item -ItemType Directory -Force -Path $repo, $cache | Out-Null
    $providers = Join-Path $root 'providers'
    $cacheRoot = Join-Path $root 'cache'
    Set-Content -LiteralPath (Join-Path (Join-Path $root 'providers\ascom\assets\sxs') 'README.md') -Value 'repo doc' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $cache 'netfx3.cab') -Value 'cache cab' -Encoding Ascii

    It 'merges the two roots, so a mixed directory arrives whole' {
        $e = @(Get-MastAssetTreeEntries -ProvidersRoot $providers -Module 'ascom' `
                  -RelativeDir 'assets\sxs' -AssetCacheRoot $cacheRoot)
        ($e | ForEach-Object { $_.Relative } | Sort-Object) -join ',' |
            Should Be '19044\netfx3.cab,README.md'
    }

    It 'keeps the staging-relative path, so the tree is reproduced not flattened' {
        $e = @(Get-MastAssetTreeEntries -ProvidersRoot $providers -Module 'ascom' `
                  -RelativeDir 'assets\sxs' -AssetCacheRoot $cacheRoot)
        ($e | Where-Object { $_.Relative -eq '19044\netfx3.cab' }).Source |
            Should Be (Join-Path $cache 'netfx3.cab')
    }

    It 'prefers the repo when both roots hold the same relative path' {
        Set-Content -LiteralPath (Join-Path $cache 'both.cab') -Value 'cache' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $repo 'both.cab')  -Value 'repo'  -Encoding Ascii
        $e = @(Get-MastAssetTreeEntries -ProvidersRoot $providers -Module 'ascom' `
                  -RelativeDir 'assets\sxs' -AssetCacheRoot $cacheRoot)
        $hit = ($e | Where-Object { $_.Relative -eq '19044\both.cab' })
        @($hit).Count | Should Be 1
        (Get-Content -LiteralPath $hit.Source -Raw).Trim() | Should Be 'repo'
    }

    It 'resolves entirely to the cache for a tree the repo never carries' {
        # The astrometry index seed and the frozen cygwin cache were never in git.
        $only = Join-Path $root 'cache\server\providers\imdisk\assets\mast-indexes'
        New-Item -ItemType Directory -Force -Path $only | Out-Null
        Set-Content -LiteralPath (Join-Path $only 'index-5202-01.fits') -Value 'x' -Encoding Ascii
        $e = @(Get-MastAssetTreeEntries -ProvidersRoot $providers -Module 'imdisk' `
                  -RelativeDir 'assets\mast-indexes' -AssetCacheRoot $cacheRoot)
        @($e).Count | Should Be 1
        $e[0].Relative | Should Be 'index-5202-01.fits'
    }

    It 'returns nothing when neither root has the tree, so the caller reports it' {
        $e = @(Get-MastAssetTreeEntries -ProvidersRoot $providers -Module 'nosuch' `
                  -RelativeDir 'assets\nothing' -AssetCacheRoot $cacheRoot)
        @($e).Count | Should Be 0
    }

    It 'ignores the cache when no cache root is configured' {
        $e = @(Get-MastAssetTreeEntries -ProvidersRoot $providers -Module 'ascom' `
                  -RelativeDir 'assets\sxs' -AssetCacheRoot '')
        ($e | ForEach-Object { $_.Relative } | Sort-Object) -join ',' |
            Should Be '19044\both.cab,README.md'
    }
}

Describe 'Resolve-MastCachedFile' {
    # The rule both resolvers are expressed in. It takes two formed paths and no
    # repo layout: a provider asset is keyed off <top>\server\providers and the
    # bootstrap media off <top>, so deriving either here would be wrong for one.

    $root = Join-Path $env:TEMP ("mast-cachedfile-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'top'), (Join-Path $root 'cache') | Out-Null
    $repoPath  = Join-Path $root 'top\npcap.exe'
    $cachePath = Join-Path $root 'cache\npcap.exe'

    It 'prefers the repo copy while one exists' {
        Set-Content -LiteralPath $repoPath  -Value 'repo'  -Encoding Ascii
        Set-Content -LiteralPath $cachePath -Value 'cache' -Encoding Ascii
        (Get-Content -LiteralPath (Resolve-MastCachedFile -RepoPath $repoPath -CachePath $cachePath) -Raw).Trim() |
            Should Be 'repo'
    }

    It 'falls through to the cache once the repo copy is gone' {
        Remove-Item -LiteralPath $repoPath -Force
        (Get-Content -LiteralPath (Resolve-MastCachedFile -RepoPath $repoPath -CachePath $cachePath) -Raw).Trim() |
            Should Be 'cache'
    }

    It 'returns the repo path when neither has it, so the caller names the expected location' {
        Remove-Item -LiteralPath $cachePath -Force
        Resolve-MastCachedFile -RepoPath $repoPath -CachePath $cachePath | Should Be $repoPath
    }

    It 'ignores an unset cache path rather than guessing one' {
        Resolve-MastCachedFile -RepoPath $repoPath | Should Be $repoPath
    }
}
