# Hash helpers for build-manifest.json. Dot-sourceable and side-effect-free so
# server/tests/build-manifest-lib.Tests.ps1 can exercise them without running a
# build; build-mast.ps1 dot-sources this file (single source of truth).

# Rolling SHA-256 over every staged file: the whole-payload "anything changed
# at all?" gate consumed by check-and-provision.ps1 / server/prov/driver.py.
function Get-PayloadHash {
    param([Parameter(Mandatory)][string]$StagingDir)

    # Hash inputs: every regular file under the staging dir, in lexical order,
    # combining "<relative-path>:<sha256>" into a single rolling hash.
    # commands.json is included implicitly. build-manifest.json is excluded
    # (we are generating it now).
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.IO.MemoryStream]::new()
    $files = Get-ChildItem -Path $StagingDir -File -Recurse |
                Where-Object { $_.Name -ne 'build-manifest.json' } |
                Sort-Object FullName
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($StagingDir.Length).TrimStart('\','/').Replace('\','/')
        $fileHash = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
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
# Category prefixes (file:/cmd:/version:) keep the input lines collision-free.
function Get-ModuleContentHash {
    param(
        [Parameter(Mandatory)][string]$ProviderDir,
        [string[]]$CommandFiles = @(),
        [string[]]$Commands = @(),
        [string]$Version = ''
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
