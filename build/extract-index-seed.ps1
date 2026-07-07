#requires -RunAsAdministrator
<#
.SYNOPSIS
    One-time: extract the astrometry index FITS files (the "seed") out of the
    legacy monolithic 15 GB ImDisk image into a plain directory.

    CANDIDATE FOR DELETION. This is a transitional bootstrap helper to get the
    seed out of the old 15 GB image once. The intended long-term source of the
    index FITS files is a .zip held on a local storage server (e.g.
    mast-wis-control, mast-ns-control, or the provisioning server itself), which
    build-mast will pull/stage directly -- at which point this script can be
    removed. Until that is in place it is kept (and committed) so the seed can be
    reproduced from the legacy image on any build host.

.DESCRIPTION
    The imdisk provider no longer ships a pre-baked filesystem image. Instead it
    builds a sparse 32 GB NTFS image on the unit and seeds it with the index
    files staged from C:\MAST\mast-indexes (see build-mast.ps1 and
    server/providers/imdisk/provide-imdisk.ps1).

    This script populates that seed directory once on the build host by mounting
    the legacy image read-only and robocopying its mast-indexes folder out. It is
    idempotent: if the destination already holds index files it does nothing
    unless -Force is passed.

    Requires elevation (ImDisk attach/detach) and ImDisk installed on the build
    host (C:\Windows\System32\imdisk.exe).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\extract-index-seed.ps1
#>
[CmdletBinding()]
param(
    [string]${ImagePath}   = 'C:\MAST\MAST-15GB-indexes-5202+5203.img',
    [string]${DestDir}     = 'C:\MAST\mast-indexes',
    [string]${IndexSubdir} = 'mast-indexes',
    [switch]${Force}
)

${ErrorActionPreference} = 'Stop'

function Write-Step { param([string]${m}) Write-Host ("[extract-index-seed] {0}" -f ${m}) }

${imdiskExe} = 'C:\Windows\System32\imdisk.exe'
if (-not (Test-Path ${imdiskExe})) {
    throw "ImDisk not found at ${imdiskExe}. Install ImDisk Toolkit on the build host first."
}
if (-not (Test-Path -LiteralPath ${ImagePath})) {
    throw "Legacy index image not found at ${ImagePath}."
}

# Idempotency: skip if the destination already has index files.
if ((Test-Path -LiteralPath ${DestDir}) -and -not ${Force}) {
    ${existing} = @(Get-ChildItem -LiteralPath ${DestDir} -File -Recurse -ErrorAction SilentlyContinue)
    if (${existing}.Count -gt 0) {
        Write-Step ("Seed already present at {0} ({1} files). Use -Force to rebuild. Nothing to do." -f ${DestDir}, ${existing}.Count)
        exit 0
    }
}

# Pick a free scratch drive letter (Z: down to E:).
${scratch} = $null
foreach (${ch} in [char[]]([char]'Z'..[char]'E')) {
    if (-not (Test-Path -LiteralPath ("{0}:\" -f ${ch}))) { ${scratch} = [string]${ch}; break }
}
if ($null -eq ${scratch}) { throw "No free drive letter available for the scratch mount." }
${scratchVol}  = "{0}:" -f ${scratch}
${scratchRoot} = "{0}:\" -f ${scratch}

Write-Step ("Mounting {0} read-only at {1}..." -f ${ImagePath}, ${scratchVol})
# -o ro = read-only; we never write to the legacy image.
${mp} = Start-Process -FilePath ${imdiskExe} `
    -ArgumentList @('-a', '-m', ${scratchVol}, '-o', 'ro', '-f', ${ImagePath}) `
    -PassThru -Wait -WindowStyle Hidden
try { ${mp}.Refresh() } catch {}
if ($null -eq ${mp}.ExitCode -or ${mp}.ExitCode -ne 0) {
    throw ("imdisk attach (read-only) failed (exit {0})." -f ${mp}.ExitCode)
}

try {
    ${tries} = 0
    while ((-not (Test-Path -LiteralPath ${scratchRoot})) -and (${tries} -lt 25)) {
        Start-Sleep -Milliseconds 200; ${tries}++
    }
    if (-not (Test-Path -LiteralPath ${scratchRoot})) {
        throw ("Scratch mount {0} did not surface." -f ${scratchVol})
    }

    ${src} = Join-Path ${scratchRoot} ${IndexSubdir}
    if (-not (Test-Path -LiteralPath ${src})) {
        throw ("Image does not contain {0} (expected {1})." -f ${IndexSubdir}, ${src})
    }

    if (${Force} -and (Test-Path -LiteralPath ${DestDir})) {
        Write-Step ("-Force: clearing existing {0}" -f ${DestDir})
        Remove-Item -LiteralPath ${DestDir} -Recurse -Force
    }
    New-Item -ItemType Directory -Path ${DestDir} -Force | Out-Null

    Write-Step ("Copying index files: {0} -> {1}" -f ${src}, ${DestDir})
    & robocopy "${src}" "${DestDir}" '/E' '/COPY:DAT' '/R:1' '/W:1' '/NFL' '/NDL' '/NP' | Out-Null
    ${rc} = ${LASTEXITCODE}
    if (${rc} -ge 8) { throw ("robocopy failed (exit {0})." -f ${rc}) }

    ${copied} = @(Get-ChildItem -LiteralPath ${DestDir} -File -Recurse -ErrorAction SilentlyContinue)
    ${gb} = ((${copied} | Measure-Object Length -Sum).Sum / 1GB)
    Write-Step ("Done: {0} files, {1:N2} GB at {2} (robocopy rc={3})." -f ${copied}.Count, ${gb}, ${DestDir}, ${rc})
}
finally {
    Write-Step ("Detaching {0}..." -f ${scratchVol})
    & ${imdiskExe} -D -m ${scratchVol} 2>&1 | Out-Null
}

exit 0
