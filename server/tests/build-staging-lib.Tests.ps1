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
