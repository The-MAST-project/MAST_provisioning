<#
.SYNOPSIS
    One-time: harvest the frozen Cygwin package cache from a working unit into
    the build-host vendor path C:\MAST\cygwin-pkg-cache.

.DESCRIPTION
    provide-astrometry-dependencies.ps1 installs Cygwin FULLY OFFLINE
    (setup-x86_64.exe --local-install) from a frozen package cache staged into
    the payload by build-mast.ps1. The cache is build-host-vendored (like the
    astrometry index seed at C:\MAST\mast-indexes) -- too churn-prone and too
    binary to keep in git -- and this script populates it once per build host.

    The authoritative source is a working unit's own setup download cache
    (C:\cygwin64\var\cache\setup, ~174 MB on mast01): it holds the exact
    cygwin-3.6.9-1 base + the full astrometry dependency closure + the
    matching setup.ini, i.e. it IS what the validated fleet installed.

    LOCKED COUPLING: the frozen cygwin version in this cache (3.6.9-1) and the
    bundled fitsio wheel tag (fitsio-*-cygwin_3_6_9_x86_64.whl in
    server/providers/astrometry-dependencies/assets/) move together. Refreshing
    the cache to a newer cygwin REQUIRES rebuilding the wheel in the same
    change (see DEPENDENCIES.md "Building the fitsio wheel"), or pip rejects
    the wheel ("not a supported wheel on this platform") -- exactly the drift
    that motivated the freeze (issue #20).

    Default source is the unit's admin share; if the build host cannot reach
    the unit directly, copy the tree by any other means (scp via a bastion,
    USB, ...) to a local directory and pass it as -SourcePath.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\harvest-cygwin-cache.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\harvest-cygwin-cache.ps1 -SourcePath D:\staged-cygwin-cache
#>
[CmdletBinding()]
param(
    [string]${UnitHost}      = 'mast01',
    # Where to copy the cache tree from. Default: the unit's admin share.
    [string]${SourcePath}    = '',
    [string]${DestDir}       = 'C:\MAST\cygwin-pkg-cache',
    # The cygwin base package release the cache must contain (the version the
    # bundled fitsio wheel is built against). Validation fails without it.
    [string]${FrozenCygwin}  = 'cygwin-3.6.9-1',
    [switch]${Force}
)

${ErrorActionPreference} = 'Stop'

function Write-Step { param([string]${m}) Write-Host ("[harvest-cygwin-cache] {0}" -f ${m}) }

if ([string]::IsNullOrEmpty(${SourcePath})) {
    ${SourcePath} = "\\{0}\c$\cygwin64\var\cache\setup" -f ${UnitHost}
}

function Test-CacheTree {
    param([Parameter(Mandatory)][string]${Dir})
    # A usable cache holds at least one mirror setup.ini and the frozen cygwin
    # base tarball somewhere under the URL-encoded mirror tree.
    ${ini}  = @(Get-ChildItem -LiteralPath ${Dir} -Filter 'setup.ini' -File -Recurse -ErrorAction SilentlyContinue)
    ${base} = @(Get-ChildItem -LiteralPath ${Dir} -Filter ("{0}-x86_64.tar.*" -f ${FrozenCygwin}) -File -Recurse -ErrorAction SilentlyContinue)
    return (${ini}.Count -gt 0 -and ${base}.Count -gt 0)
}

# Idempotency: skip if the destination is already a valid cache.
if ((Test-Path -LiteralPath ${DestDir}) -and -not ${Force}) {
    if (Test-CacheTree -Dir ${DestDir}) {
        ${existing} = @(Get-ChildItem -LiteralPath ${DestDir} -File -Recurse -ErrorAction SilentlyContinue)
        Write-Step ("Cache already present and valid at {0} ({1} files). Use -Force to re-harvest. Nothing to do." -f ${DestDir}, ${existing}.Count)
        exit 0
    }
}

if (-not (Test-Path -LiteralPath ${SourcePath})) {
    throw ("Source cache not reachable at {0}. If the unit's admin share is not reachable from this host, copy C:\cygwin64\var\cache\setup off the unit by other means and pass it as -SourcePath." -f ${SourcePath})
}
if (-not (Test-CacheTree -Dir ${SourcePath})) {
    throw ("Source {0} does not look like a cygwin setup cache (need setup.ini + {1}-x86_64.tar.* somewhere under it)." -f ${SourcePath}, ${FrozenCygwin})
}

if (${Force} -and (Test-Path -LiteralPath ${DestDir})) {
    Write-Step ("-Force: clearing existing {0}" -f ${DestDir})
    Remove-Item -LiteralPath ${DestDir} -Recurse -Force
}
New-Item -ItemType Directory -Path ${DestDir} -Force | Out-Null

Write-Step ("Copying cache: {0} -> {1}" -f ${SourcePath}, ${DestDir})
& robocopy "${SourcePath}" "${DestDir}" '/E' '/COPY:DAT' '/R:2' '/W:2' '/NFL' '/NDL' '/NP' | Out-Null
${rc} = ${LASTEXITCODE}
if (${rc} -ge 8) { throw ("robocopy failed (exit {0})." -f ${rc}) }

if (-not (Test-CacheTree -Dir ${DestDir})) {
    throw ("Copy finished but {0} fails validation (setup.ini or {1}-x86_64.tar.* missing)." -f ${DestDir}, ${FrozenCygwin})
}
${copied} = @(Get-ChildItem -LiteralPath ${DestDir} -File -Recurse -ErrorAction SilentlyContinue)
${mb} = ((${copied} | Measure-Object Length -Sum).Sum / 1MB)
Write-Step ("Done: {0} files, {1:N0} MB at {2} (robocopy rc={3})." -f ${copied}.Count, ${mb}, ${DestDir}, ${rc})
exit 0
