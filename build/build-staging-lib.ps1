# Staging helpers for build-mast.ps1. Dot-sourceable and side-effect-free so
# server/tests/build-staging-lib.Tests.ps1 can exercise them without running a
# build; build-mast.ps1 dot-sources this file (single source of truth).

# Resolve a module.json 'repofiles' entry to an absolute path under the repo top.
#
# WHY THIS KEY EXISTS: a module's deployed output can depend on a file that
# lives OUTSIDE its provider directory -- the 'mast' module runs
# tools/mast-clone.ps1, which is shared with the control host and with dev
# boxes. Two obvious alternatives are both wrong:
#   - copying the file into server/providers/<module>/ at build time forks the
#     single source of truth the shared tool exists to be;
#   - a '../../tools/mast-clone.ps1' entry in 'commandfiles' resolves correctly
#     on the SOURCE side but, because the staging pass mirrors the relative
#     path, writes OUTSIDE the staging root on the destination side.
# So 'repofiles' is its own key: paths relative to the repo top, staged to the
# staging root by leaf name (the same flattening 'assets/*' already gets).
#
# The containment check is the point of the function. An entry is rejected if it
# is absolute, contains a '..' segment, or resolves outside the repo top --
# a build must not reach arbitrary paths on the build host, and a typo should
# fail loudly at build time rather than silently stage nothing.
function Resolve-MastRepoFile {
    param(
        [Parameter(Mandatory)][string]$RepoTop,
        [Parameter(Mandatory)][string]$RelativePath,
        [string]$ModuleName = ''
    )

    $label = if ($ModuleName) { "[$ModuleName] repofiles entry" } else { 'repofiles entry' }

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "${label}: empty path"
    }
    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "${label}: must be relative to the repo top, got absolute path '${RelativePath}'"
    }

    $norm = $RelativePath -replace '\\', '/'
    foreach ($seg in ($norm -split '/')) {
        if ($seg -eq '..') {
            throw "${label}: '..' is not allowed, got '${RelativePath}'"
        }
    }

    # GetFullPath normalises separators and any '.' segments. RepoTop is made
    # absolute first so the StartsWith comparison below cannot be defeated by a
    # relative or unnormalised top.
    $topFull = [System.IO.Path]::GetFullPath($RepoTop)
    if (-not $topFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $topFull = $topFull + [System.IO.Path]::DirectorySeparatorChar
    }
    $full = [System.IO.Path]::GetFullPath((Join-Path $topFull $norm))

    # Belt and braces: '..' is already rejected above, but a symlink or an
    # exotic path form should not be able to escape either.
    if (-not $full.StartsWith($topFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "${label}: '${RelativePath}' resolves outside the repo top"
    }

    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "${label}: missing file '${RelativePath}' (looked in '${full}')"
    }

    return $full
}

# The staging destination for a repofiles entry: the staging root, by leaf name.
# Flattened like 'assets/*' because the unit-side executor runs every command
# with the staging root as its working directory, so a nested path would not be
# found by a '.\mast-clone.ps1' style invocation.
function Get-MastRepoFileStagingPath {
    param(
        [Parameter(Mandatory)][string]$StagingDir,
        [Parameter(Mandatory)][string]$RelativePath
    )
    $leaf = Split-Path ($RelativePath -replace '\\', '/') -Leaf
    return (Join-Path $StagingDir $leaf)
}

# Read a module manifest's 'repofiles' as a string array, tolerating absence.
# Kept here rather than inline so the build loop and the per-module content hash
# read the key exactly the same way.
function Get-MastModuleRepoFiles {
    param([Parameter(Mandatory)]$Manifest)

    if (-not $Manifest.PSObject.Properties.Match('repofiles').Count) { return @() }
    if (-not $Manifest.repofiles) { return @() }
    return @($Manifest.repofiles | ForEach-Object { [string]$_ } | Where-Object { $_ })
}

# Which vendored Jupyter wheels disagree with the interpreter the 'python'
# provider pins.
#
# WHY THIS EXISTS: the jupyter provider installs its vendored wheelhouse with
# '--no-index --find-links', so pip has no index to fall back on -- a wheel built
# for a different CPython does not resolve to something else, it resolves to
# nothing and the module fails on every unit. Fifteen of those wheels are
# 'cp312-cp312-win_amd64', bound to an interpreter version declared in a
# DIFFERENT module (server/providers/python/module.json). Bumping Python is a
# small, local-looking edit in that provider that invalidates wheels in this one,
# and nothing in the repo connected the two (#180). The same shape has bitten
# once already: cygwin is pinned to 3.6.9 to match the bundled fitsio wheel tag,
# found when a rolling mirror moved past it (#20).
#
# Filenames only, no file content: this works against LFS pointers and needs no
# Python on the build host.
#
# Three tag families, three rules. A wheel name's last three '-'-separated fields
# are the python tag, the ABI tag and the platform:
#   py3-none-any       pure Python, indifferent to the interpreter -- ignored.
#   cpXY-abi3-<plat>   stable ABI, so cpXY is the MINIMUM it runs on; anything up
#                      to and including the target is fine. The seven abi3 wheels
#                      in the tree declare cp37..cp312.
#   cpXY-cpXY-<plat>   version-locked; must equal the target exactly.
# Returns a list of human-readable reasons, empty when everything agrees. The
# caller owns the message, so this stays testable without a build.
function Get-MastWheelInterpreterMismatches {
    param(
        [Parameter(Mandatory)][string]$PythonVersion,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$WheelNames
    )

    $want = [regex]::Match($PythonVersion, '^(\d+)\.(\d+)')
    if (-not $want.Success) {
        throw "Cannot read a major.minor version from the python provider's declared version '${PythonVersion}'."
    }
    $wantMajor = [int]$want.Groups[1].Value
    $wantMinor = [int]$want.Groups[2].Value
    $wantTag = 'cp{0}{1}' -f $wantMajor, $wantMinor

    $reasons = @()
    foreach ($name in @($WheelNames)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $leaf = Split-Path ($name -replace '\\', '/') -Leaf
        if ($leaf -notlike '*.whl') { continue }

        $fields = @(($leaf -replace '\.whl$', '') -split '-')
        if ($fields.Count -lt 3) {
            $reasons += "${leaf}: not a wheel name (expected name-version[-build]-pytag-abitag-platform.whl)"
            continue
        }
        $pyTag = $fields[$fields.Count - 3]
        $abiTag = $fields[$fields.Count - 2]

        # Only CPython-version-locked tags carry a constraint. 'py3', 'py2.py3'
        # and a PyPy 'pp310' all fall out here, which is the intended silence.
        $tag = [regex]::Match($pyTag, '^cp(\d)(\d+)$')
        if (-not $tag.Success) { continue }
        $tagMajor = [int]$tag.Groups[1].Value
        $tagMinor = [int]$tag.Groups[2].Value

        if ($abiTag -eq 'abi3') {
            if ($tagMajor -gt $wantMajor -or ($tagMajor -eq $wantMajor -and $tagMinor -gt $wantMinor)) {
                $reasons += "${leaf}: stable-ABI minimum ${pyTag} is newer than ${wantTag}"
            }
            continue
        }

        if ($pyTag -ne $wantTag) {
            $reasons += "${leaf}: built for ${pyTag}, needs ${wantTag}"
        }
    }
    return @($reasons)
}
