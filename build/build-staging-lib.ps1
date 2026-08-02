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
