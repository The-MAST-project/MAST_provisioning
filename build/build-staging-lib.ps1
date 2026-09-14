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

# The identity of the repo manifest: what the mast module deploys.
#
# Reported as that module's version, in place of the provisioning repo's SHA.
# The manifest is already inside the module's content hash (it is a repofile), so
# this changes no drift decision -- it makes the reported version mean "which set
# of MAST revisions is this unit meant to be on" rather than "which commit of
# THIS repo happened to build the payload".
#
# Short hash rather than the full digest: it is a reporting field read by humans
# in fleet-drift-report and in module_state, and 12 hex is plenty to tell two
# manifests apart.
function Get-MastReposManifestVersion {
    param([Parameter(Mandatory)][string]$RepoTop)
    $manifest = Join-Path $RepoTop 'tools\mast-repos.tsv'
    if (-not (Test-Path -LiteralPath $manifest)) {
        throw "Cannot version the mast module: no repo manifest at ${manifest}"
    }
    $sha = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
    return ('repos-' + $sha.Substring(0, 12))
}

# Staging-root entries that no module claims, with their sizes.
#
# There must be none: prov.payload rejects a manifest it cannot fully account
# for, so build-mast.ps1 throws on a non-empty result rather than shipping a
# payload whose contents no rule describes. A hit means a staging block that
# called neither Add-MastStagedPayload nor Add-MastAlwaysStagedPayload.
#
# Sizes descend into directories, matching what robocopy moves.
function Get-MastUnattributedStagedEntries {
    param(
        [Parameter(Mandatory)][string]$StagingDir,
        [Parameter(Mandatory)]$Map,
        [Parameter(Mandatory)]$Always
    )

    $claimed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($module in $Map.Keys) {
        foreach ($bucket in 'files', 'dirs') {
            foreach ($name in @($Map[$module][$bucket])) { [void]$claimed.Add($name) }
        }
    }
    foreach ($bucket in 'files', 'dirs') {
        foreach ($name in @($Always[$bucket])) { [void]$claimed.Add($name) }
    }

    $out = @()
    foreach ($entry in (Get-ChildItem -LiteralPath $StagingDir -Force -ErrorAction SilentlyContinue)) {
        if ($claimed.Contains($entry.Name)) { continue }
        $bytes = if ($entry.PSIsContainer) {
            (Get-ChildItem -LiteralPath $entry.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        } else {
            $entry.Length
        }
        $out += [pscustomobject]@{ Name = $entry.Name; Bytes = [int64]($bytes | ForEach-Object { if ($null -eq $_) { 0 } else { $_ } }) }
    }
    return @($out)
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

# Is a module.json 'commandfiles' entry an ASSET (as opposed to a script)?
#
# The distinction decides what the transfer may leave behind. build-mast.ps1
# flattens 'assets/*' to the staging root by leaf name and keeps everything else
# at its relative path, and only the flattened assets are recorded as a module's
# payload (Add-MastStagedPayload) and therefore excludable when no targeted
# module claims them (MAST_provisioning#186).
#
# Scripts are never excludable, and the reason is run-verify-only.ps1: it is
# operator-run, defaults to EVERY verify command in commands.json, and writes the
# tier-2 validation.json that per-module drift classification reads. A payload
# missing an untargeted module's verify script would fail that module there and
# manufacture needs-repair drift on a unit that is fine.
function Test-MastCommandFileIsAsset {
    param([Parameter(Mandatory)][string]$CommandFile)
    return (($CommandFile -replace '\\', '/') -like 'assets/*')
}

# A fresh module -> staged payload map, in build order.
function New-MastStagedPayloadMap {
    return [ordered]@{}
}

# The staging-ROOT entry a non-asset commandfile lands under.
#
# Exclusions name root entries, so that is the granularity to record. A flat
# 'provide-x.ps1' is itself the root entry; a nested 'sites/ns.toml' keeps its
# relative path in staging, so the root entry is the DIRECTORY 'sites'. Getting
# this wrong records a name that is not at the root and leaves the real entry
# unaccounted -- which is how config-bootstrap's sites\ slipped through.
function Get-MastStagingRootName {
    param([Parameter(Mandatory)][string]$RelativePath)
    $norm = $RelativePath -replace '\\', '/'
    $head = $norm.Split('/')[0]
    return [pscustomobject]@{ Name = $head; IsDir = $norm.Contains('/') }
}

# A fresh always-ship record: what every run needs whatever it targets.
function New-MastAlwaysPayload {
    return [ordered]@{ files = @(); dirs = @() }
}

# Record a staged root entry that belongs to no single module and must never be
# excluded: the client scripts, each provider's provide-/verify- scripts, the
# repofiles, commands.json, build-manifest.json.
#
# These are recorded rather than left to a default. An unrecorded entry used to
# ship anyway, which meant a staging block that forgot to record cost the saving
# in silence -- 2.1 GB of PlateSolve3 catalog did exactly that. With every entry
# recorded the build can assert completeness, and 'what --force sends' and 'what
# targeting every module sends' become the same set by construction rather than
# by a catch-all (MAST_provisioning#186).
function Add-MastAlwaysStagedPayload {
    param(
        [Parameter(Mandatory)]$Payload,
        [string]$File = '',
        [string]$Dir = ''
    )

    if (([string]::IsNullOrWhiteSpace($File)) -eq ([string]::IsNullOrWhiteSpace($Dir))) {
        throw 'Add-MastAlwaysStagedPayload: pass exactly one of -File and -Dir'
    }
    $bucket = if ($File) { 'files' } else { 'dirs' }
    $name = if ($File) { $File } else { $Dir }
    if ($name -match '[\\/]') {
        throw "Add-MastAlwaysStagedPayload: '${name}' must be a staging-root leaf name, not a path"
    }
    if (@($Payload[$bucket]) -notcontains $name) {
        $Payload[$bucket] = @($Payload[$bucket]) + $name
    }
}

# Record one staged root-level entry against the module that caused it to be
# staged. Emitted as build-manifest.json's 'module_payload' and consumed by
# prov.payload to decide what a targeted run may leave on the server.
#
# An entry may have SEVERAL claimants and must then survive if any one of them is
# targeted: full-frame.fits is staged for astrometry OR mast-validation, and leaf
# flattening lets two providers collide on one name. So this accumulates rather
# than assigns, and the consumer inverts to entry -> {modules} and excludes only
# on an empty intersection.
#
# Names are the STAGING leaf, never the source-relative path: the staging root is
# flat and the consumer turns these into robocopy exclusions under it, so a
# nested name would produce an exclusion that matches nothing.
function Add-MastStagedPayload {
    param(
        [Parameter(Mandatory)]$Map,
        [Parameter(Mandatory)][string]$Module,
        [string]$File = '',
        [string]$Dir = ''
    )

    if ([string]::IsNullOrWhiteSpace($Module)) {
        throw 'Add-MastStagedPayload: -Module is required'
    }
    if (([string]::IsNullOrWhiteSpace($File)) -eq ([string]::IsNullOrWhiteSpace($Dir))) {
        throw "[${Module}] Add-MastStagedPayload: pass exactly one of -File and -Dir"
    }

    $bucket = if ($File) { 'files' } else { 'dirs' }
    $name = if ($File) { $File } else { $Dir }

    if ($name -match '[\\/]') {
        throw "[${Module}] Add-MastStagedPayload: '${name}' must be a staging-root leaf name, not a path"
    }

    if (-not $Map.Contains($Module)) {
        $Map[$Module] = [ordered]@{ files = @(); dirs = @() }
    }
    if (@($Map[$Module][$bucket]) -notcontains $name) {
        $Map[$Module][$bucket] = @($Map[$Module][$bucket]) + $name
    }
}
