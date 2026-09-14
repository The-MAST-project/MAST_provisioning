# Hash helpers for build-manifest.json. Dot-sourceable and side-effect-free so
# server/tests/build-manifest-lib.Tests.ps1 can exercise them without running a
# build; build-mast.ps1 dot-sources this file (single source of truth).

# Every file under the staging tree, descending reparse points.
#
# THE ONE ENUMERATION. Get-ChildItem -Recurse does not descend reparse points,
# and build-mast stages mast-indexes and cygwin-pkg-cache as junctions when the
# build runs elevated -- so the payload hash covered 290 of 543 files, 3.84 of
# 14.88 GB, leaving the 9.9 GB index seed outside the "anything changed" gate
# entirely (#203). A re-seeded index moved no hash, so a unit was logged
# already_current against a payload whose larger half had changed.
#
# That trap has now produced three defects here -- prov/staging_size.py and
# Get-MastDirectorySize in mast-pull-staging.ps1 are the other two -- so this is
# the walk everything in the build shares rather than a fourth implementation.
#
# Cycles are guarded by resolved path: a junction pointing at an ancestor would
# otherwise recurse forever. Order is lexical by relative path so the rolling
# hash is deterministic across build hosts.
function Get-MastStagedFiles {
    param([Parameter(Mandatory)][string]$StagingDir)

    if (-not (Test-Path -LiteralPath $StagingDir)) { return @() }
    $rootFull = (Get-Item -LiteralPath $StagingDir).FullName.TrimEnd('\')
    $out = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $stack = New-Object System.Collections.Stack
    [void]$stack.Push(@{ Path = $rootFull; Rel = '' })

    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        try { $real = (Get-Item -LiteralPath $node.Path -Force).Target } catch { $real = $null }
        if (-not $real) { $real = $node.Path }
        if (-not $seen.Add([string]$real)) { continue }
        foreach ($e in (Get-ChildItem -LiteralPath $node.Path -Force -ErrorAction SilentlyContinue)) {
            $rel = if ($node.Rel) { $node.Rel + '/' + $e.Name } else { $e.Name }
            if ($e.PSIsContainer) {
                [void]$stack.Push(@{ Path = $e.FullName; Rel = $rel })
            } else {
                [void]$out.Add([pscustomobject]@{
                    RelativePath = $rel
                    FullName     = $e.FullName
                    Length       = [int64]$e.Length
                })
            }
        }
    }
    return @($out | Sort-Object RelativePath)
}

# Every staged file with its size and content hash -- the per-version manifest
# the relay assembles a payload from (#202).
#
# Free: Get-PayloadHash already hashes each of these files and discards the
# per-file value into its rolling digest. This keeps the list instead.
#
# Nothing is excluded. Get-PayloadHash skips build-manifest.json because it runs
# before that file exists; this runs after, and the file is part of the payload
# the unit installs from -- excluding it here assembled a 542-file tree against
# a 543-file payload and failed mast07's destination check (#203).
function Get-MastPayloadManifest {
    param([Parameter(Mandatory)][string]$StagingDir)

    ${entries} = New-Object System.Collections.ArrayList
    foreach ($f in (Get-MastStagedFiles -StagingDir $StagingDir)) {
        [void]${entries}.Add([ordered]@{
            path   = $f.RelativePath
            size   = $f.Length
            sha256 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
    return @(${entries})
}

# Rolling SHA-256 over every staged file: the whole-payload "anything changed
# at all?" gate consumed by server/prov/driver.py.
function Get-PayloadHash {
    param([Parameter(Mandatory)][string]$StagingDir)

    # Hash inputs: every regular file under the staging dir, in lexical order,
    # combining "<relative-path>:<sha256>" into a single rolling hash.
    # commands.json is included implicitly. build-manifest.json is excluded
    # (we are generating it now).
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.IO.MemoryStream]::new()
    # Get-MastStagedFiles, not Get-ChildItem -Recurse: see that function (#203).
    $files = Get-MastStagedFiles -StagingDir $StagingDir |
                Where-Object { $_.RelativePath -ne 'build-manifest.json' }
    foreach ($f in $files) {
        $rel = $f.RelativePath
        $fileHash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $line = [System.Text.Encoding]::UTF8.GetBytes("$rel`:$fileHash`n")
        $bytes.Write($line, 0, $line.Length)
    }
    $bytes.Position = 0
    $digest = $sha.ComputeHash($bytes)
    return ([System.BitConverter]::ToString($digest) -replace '-','').ToLowerInvariant()
}

# Per-module content hash: covers every repo-tracked determinant of the
# module's deployed output, not just the payload bytes --
#   - the module's source commandfiles (bytes, keyed by their module.json
#     relative path; hashed from server/providers/<module>/, NOT from staging,
#     which is flattened and has no per-module subtree);
#   - the RESOLVED command strings for the module (provide + verify + any
#     extra entries) exactly as emitted to commands.json, so build-time
#     injected args (-Site, -ForceMode, -RpiNtp, ...) are inside the hash
#     boundary -- a repointed shortcut URL or site switch registers as drift
#     even when no commandfile byte changed;
#   - the resolved version string ('git' already substituted by the caller,
#     so source-tracked modules fold the git SHA in).
# A missing commandfile is skipped: production builds have already thrown in
# the staging pass for non-optional files, so by the time hashes are computed
# a gap can only be a -TestMode optional payload (e.g. cygwin astrometry.tgz).
# Category prefixes (file:/repofile:/cmd:/version:) keep the input lines
# collision-free.
#   - RepoFiles are the module's 'repofiles' entries: shared tooling it runs from
#     the repo top (tools/mast-clone.ps1 for the mast module). They determine the
#     module's deployed output exactly as its commandfiles do, so they are inside
#     the hash boundary; a change to mast-clone.ps1 must drift the mast module,
#     not merely the aggregate payload_hash. Hashed under their repo-relative
#     path, from -RepoTop.
function Get-ModuleContentHash {
    param(
        [Parameter(Mandatory)][string]$ProviderDir,
        [string[]]$CommandFiles = @(),
        [string[]]$Commands = @(),
        [string]$Version = '',
        [string]$RepoTop = '',
        [string[]]$RepoFiles = @()
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.IO.MemoryStream]::new()
    $lines = @()
    foreach ($cf in (@($CommandFiles) | Where-Object { $_ } | Sort-Object)) {
        $norm = ($cf -replace '\\','/')
        $path = Join-Path $ProviderDir $cf
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $fileHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines += "file:$norm`:$fileHash"
    }
    foreach ($rf in (@($RepoFiles) | Where-Object { $_ } | Sort-Object)) {
        $norm = ($rf -replace '\\','/')
        if (-not $RepoTop) { throw "Get-ModuleContentHash: -RepoFiles given without -RepoTop" }
        $path = Join-Path $RepoTop $rf
        # Unlike a commandfile, a missing repofile is never a -TestMode optional
        # payload -- the staging pass has already thrown for it. Reaching here
        # with one absent means the manifest and the tree disagree; say so.
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Get-ModuleContentHash: repofile not found: $rf (looked in $RepoTop)"
        }
        $fileHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines += "repofile:$norm`:$fileHash"
    }
    # Commands keep their caller order (commands.json order), NOT sorted:
    # execution order is part of the deployed behavior.
    foreach ($c in @($Commands) | Where-Object { $_ }) {
        $lines += "cmd:$c"
    }
    $lines += "version:$Version"
    foreach ($l in $lines) {
        $b = [System.Text.Encoding]::UTF8.GetBytes("$l`n")
        $bytes.Write($b, 0, $b.Length)
    }
    $bytes.Position = 0
    $digest = $sha.ComputeHash($bytes)
    return ([System.BitConverter]::ToString($digest) -replace '-','').ToLowerInvariant()
}
