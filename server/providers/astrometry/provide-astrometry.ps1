#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]${AssetsRoot}     = ${PSScriptRoot},
    [string]${ArchiveName}    = 'astrometry.tgz',
    [string]${InstallRoot}    = 'C:\cygwin64\usr\local\astrometry',
    [string]${CygwinBashExe}  = 'C:\cygwin64\bin\bash.exe'
)

# --- Import shared helpers (PS 5.1 safe) ---
try {
    ${provLocal}  = Join-Path ${PSScriptRoot} 'provisioning.psm1'
    ${provGlobal} = 'C:\ProgramData\MAST\provisioning.psm1'
    if (Test-Path ${provLocal}) {
        Import-Module ${provLocal} -Force -ErrorAction Stop -DisableNameChecking
    }
    elseif (Test-Path ${provGlobal}) {
        Import-Module ${provGlobal} -Force -ErrorAction Stop -DisableNameChecking
    }
    else {
        throw "provisioning.psm1 not found next to script or in ${provGlobal}"
    }
}
catch {
    throw "Failed to import provisioning.psm1: $($_.Exception.Message)"
}

${log} = Start-ProvisionLog -Component 'provide-astrometry'
try {
    ${archivePath} = Join-Path ${AssetsRoot} ${ArchiveName}
    if (-not (Test-Path ${archivePath})) {
        throw "Astrometry archive not found: ${archivePath}"
    }
    if (-not (Test-Path ${CygwinBashExe})) {
        throw "Cygwin bash not found at ${CygwinBashExe}. 'cygwin' provider must run before 'astrometry'."
    }

    # Sanity-check that astrometry-dependencies has populated C:\cygwin64\bin with
    # the runtime DLLs we need. Failing here gives a clearer error than letting
    # solve-field die later with STATUS_ENTRYPOINT_NOT_FOUND.
    ${binDir} = Split-Path -Parent ${CygwinBashExe}
    ${required} = @('cygcfitsio-10.dll','cygwcs-4.dll','cygnetpbm-10.dll','libpython3.9.dll')
    foreach (${d} in ${required}) {
        if (-not (Test-Path (Join-Path ${binDir} ${d}))) {
            throw "Required Cygwin DLL missing: ${d}. Run 'astrometry-dependencies' provider first."
        }
    }

    # Wipe any prior install so the tarball lands cleanly. astrometry.tgz contains
    # everything under ./bin ./etc ./lib etc., so re-extracting on top of an existing
    # tree would leave orphan files from a previous version.
    if (Test-Path ${InstallRoot}) {
        Write-Host "Removing existing ${InstallRoot} ..."
        Remove-Item -LiteralPath ${InstallRoot} -Recurse -Force
    }
    Confirm-Dir ${InstallRoot}

    Write-Host "Expanding ${archivePath} -> ${InstallRoot} ..."
    Expand-AnyArchive -ArchivePath ${archivePath} -Destination ${InstallRoot}

    # Sanity: the canonical solve-field.exe must exist.
    ${solveField} = Join-Path ${InstallRoot} 'bin\solve-field.exe'
    if (-not (Test-Path ${solveField})) {
        throw "Extraction succeeded but ${solveField} is missing. The archive may be malformed."
    }
    Write-Host "Astrometry.net expanded. solve-field: ${solveField}"

    # Place the smoke-solve FITS where verify-astrometry + mast-validation expect
    # it (C:\MAST\full-frame.fits). build-mast stages it into the payload from the
    # build host's C:\MAST\full-frame.fits. Required for a valid run -- the verify
    # stages FAIL without it (the skip paths were removed).
    ${stagedFits} = Join-Path ${AssetsRoot} 'full-frame.fits'
    ${fitsTarget} = 'C:\MAST\full-frame.fits'
    if (Test-Path -LiteralPath ${stagedFits}) {
        Confirm-Dir (Split-Path -Parent ${fitsTarget})
        Copy-Item -LiteralPath ${stagedFits} -Destination ${fitsTarget} -Force
        Write-Host ("Placed smoke FITS: {0} ({1:N1} MB)" -f ${fitsTarget}, ((Get-Item ${fitsTarget}).Length / 1MB))
    } else {
        Write-Host ("[WARN] full-frame.fits not staged at {0}; astrometry verify + mast-validation will FAIL (no smoke FITS)." -f ${stagedFits})
    }
}
finally {
    Stop-ProvisionLog
}
exit 0
