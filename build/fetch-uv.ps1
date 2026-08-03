<#
.SYNOPSIS
    Refresh the vendored uv release under the mast provider's assets.

.DESCRIPTION
    tools/mast-clone.ps1 needs uv to build the role venv. Left to itself it
    downloads the pinned release from the GitHub CDN at provisioning time, which
    puts a unit's provisioning run at the mercy of GitHub reachability from the
    observatory -- the same class of dependency the frozen Cygwin package cache
    removed for astrometry (issue #20).

    So the pinned release is VENDORED into the payload:
    server/providers/mast/assets/uv-x86_64-pc-windows-msvc.zip (+ .sha256).
    provide-mast.ps1 verifies the checksum and extracts uv.exe to
    <Top>\.tools\uv.exe before invoking mast-clone, and mast-clone prefers an
    existing <Top>\.tools\uv.exe over bootstrapping -- so no change to
    mast-clone was needed.

    The ZIP is vendored rather than the extracted uv.exe: 18 MB against 46 MB in
    git and in every payload, and shipping the publisher's .sha256 beside it
    keeps the integrity check that mast-clone's own bootstrap performs, instead
    of trusting a loose binary in the tree.

    THE VERSION IS NOT A PARAMETER. It is read from the '#!uv-version' directive
    in tools/mast-repos.tsv, which is the single source of truth shared with
    mast-clone.ps1 and mast-clone.sh. To move the fleet to a new uv: edit that
    directive, re-run this script, and commit both together -- otherwise the
    vendored zip and the version the scripts expect drift apart, and
    provide-mast.ps1 fails the run on the mismatch.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build\fetch-uv.ps1
#>
[CmdletBinding()]
param(
    # Overwrite an already-vendored zip of the same version.
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoTop  = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path $repoTop 'tools\mast-repos.tsv'
$assets   = Join-Path $repoTop 'server\providers\mast\assets'
$asset    = 'uv-x86_64-pc-windows-msvc.zip'

if (-not (Test-Path -LiteralPath $manifest)) { throw "manifest not found: $manifest" }

$version = ''
foreach ($line in (Get-Content -LiteralPath $manifest)) {
    if ($line -match '^#!uv-version\s+(\S+)') { $version = $Matches[1]; break }
}
if (-not $version) { throw "no '#!uv-version' directive in $manifest" }
Write-Host "[fetch-uv] pinned version: $version (from tools/mast-repos.tsv)"

$zipPath = Join-Path $assets $asset
$shaPath = "$zipPath.sha256"
if ((Test-Path -LiteralPath $zipPath) -and -not $Force) {
    Write-Host "[fetch-uv] $asset already vendored; pass -Force to re-download."
    return
}

$null = New-Item -ItemType Directory -Path $assets -Force
$url = "https://github.com/astral-sh/uv/releases/download/$version/$asset"
Write-Host "[fetch-uv] downloading $url"
# TLS 1.2 is not the default in Windows PowerShell 5.1; GitHub requires it.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("fetch-uv-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmp -Force
try {
    $tmpZip = Join-Path $tmp $asset
    Invoke-WebRequest -Uri $url          -OutFile $tmpZip          -UseBasicParsing
    Invoke-WebRequest -Uri "$url.sha256" -OutFile "$tmpZip.sha256" -UseBasicParsing

    $expected = ((Get-Content -LiteralPath "$tmpZip.sha256" -Raw).Trim() -split '\s+')[0]
    $actual   = (Get-FileHash -LiteralPath $tmpZip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected.ToLowerInvariant() -ne $actual) {
        throw "checksum MISMATCH -- refusing to vendor.`n  expected: $expected`n  actual:   $actual"
    }
    Write-Host "[fetch-uv] checksum verified (sha256 $actual)"

    Copy-Item -LiteralPath $tmpZip          -Destination $zipPath -Force
    Copy-Item -LiteralPath "$tmpZip.sha256" -Destination $shaPath -Force
    Write-Host "[fetch-uv] vendored -> $zipPath"
    Write-Host "[fetch-uv] commit BOTH files together with the mast-repos.tsv pin."
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
