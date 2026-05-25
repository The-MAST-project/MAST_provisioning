#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]${AssetsRoot}  = ${PSScriptRoot},
    [string]${CygwinRoot}  = 'C:\cygwin64',
    [string]${MirrorSite}  = 'https://cygwin.itefix.net',
    [string]${ProxyHost}   = 'bcproxy.weizmann.ac.il:8080',
    [string]${SetupName}   = 'setup-x86_64.exe'
)

# Top-level Cygwin packages whose runtime DLLs *and* runtime PATH tools
# astrometry.net 0.97 needs. setup-x86_64.exe resolves the transitive dependency
# closure automatically; see DEPENDENCIES.md for the full 42-package DLL
# closure this resolves to. We also list a few packages whose contribution is
# *not* a linked DLL but a PATH-resolved helper that solve-field invokes
# through /bin/sh -- those cannot be discovered by cygcheck, so they are
# enumerated explicitly here.
${Packages} = @(
    'cygwin',
    'libcfitsio10',
    'libwcs4',
    'libnetpbm10',     # cygnetpbm-10.dll (linked dep of solve-field/wcs tools)
    'netpbm',          # pnmfile etc. on PATH; solve-field calls 'pnmfile' via /bin/sh
    'libcairo2',
    'libpng16',
    'libjpeg8',
    'python39',
    'python39-numpy'   # removelines/uniformize import numpy.linalg at runtime
) -join ','

# --- Import shared helpers from provisioning.psm1 (PS 5.1 safe) ---
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

${log} = Start-ProvisionLog -Component 'provide-astrometry-dependencies'
try {
    ${setupPath} = Join-Path ${AssetsRoot} ${SetupName}
    if (-not (Test-Path ${setupPath})) {
        throw "Cygwin setup binary not found: ${setupPath}"
    }
    ${bashExe} = Join-Path (Join-Path ${CygwinRoot} 'bin') 'bash.exe'
    if (-not (Test-Path ${bashExe})) {
        throw "bash.exe not found at ${bashExe}. The 'cygwin' provider must run before this one."
    }

    # setup-x86_64.exe local-package-dir; lives under the Cygwin root so subsequent
    # re-runs (or admins doing a manual setup.exe pass) reuse the cache.
    ${pkgCache} = Join-Path ${CygwinRoot} 'var\cache\setup'
    Confirm-Dir ${pkgCache}

    # Probe the configured proxy. On a unit with direct internet access (e.g.,
    # the VirtualBox dev VM behind NAT to the host), the Weizmann internal
    # proxy is unreachable and forcing `--proxy` makes setup.exe fail every
    # fetch with WinINet error 12007. Only pass the proxy if it actually
    # answers on its port; otherwise let setup.exe go direct.
    ${useProxy} = $false
    if (${ProxyHost}) {
        ${pp} = ${ProxyHost} -split ':'
        if (${pp}.Count -eq 2) {
            ${proxyHostName} = ${pp}[0]; ${proxyPort} = [int]${pp}[1]
            try {
                ${tc} = Test-NetConnection -ComputerName ${proxyHostName} -Port ${proxyPort} `
                    -WarningAction SilentlyContinue -InformationLevel Quiet -ErrorAction Stop
                ${useProxy} = [bool]${tc}
            } catch { ${useProxy} = $false }
            Write-Host ("Proxy '{0}' reachable: {1}" -f ${ProxyHost}, ${useProxy})
        } else {
            Write-Host ("WARN: -ProxyHost '{0}' not in host:port form; skipping." -f ${ProxyHost})
        }
    }

    ${setupArgs} = @(
        '--quiet-mode',
        '--no-shortcuts','--no-desktop','--no-startmenu','--no-write-registry',
        '--upgrade-also',
        '--root', ${CygwinRoot},
        '--site', ${MirrorSite},
        '--local-package-dir', ${pkgCache},
        '--packages', ${Packages}
    )
    if (${useProxy}) {
        ${setupArgs} = @('--proxy', ${ProxyHost}) + ${setupArgs}
    }

    Write-Host ("Running ${setupPath} for packages: ${Packages} (proxy={0})" -f $(if (${useProxy}) { ${ProxyHost} } else { 'direct' }))
    ${proc} = Start-Process -FilePath ${setupPath} -ArgumentList ${setupArgs} `
        -Wait -PassThru -NoNewWindow
    try { ${proc}.Refresh() } catch {}
    ${exit} = ${proc}.ExitCode
    if ($null -eq ${exit}) {
        throw "setup-x86_64.exe did not report an exit code (treating as failure)."
    }
    if (${exit} -ne 0) {
        throw "setup-x86_64.exe failed with exit code ${exit}. See ${CygwinRoot}\var\log\setup.log.full"
    }
    Write-Host "setup-x86_64.exe completed (exit ${exit})."

    # Add the Cygwin lapack DLL directory to the *machine* PATH. Cygwin's
    # lapack package installs cyglapack-0.dll under /usr/lib/lapack (NOT
    # /usr/bin) and ships /etc/profile.d/lapack0.sh to append that path
    # in interactive login shells. solve-field forks /bin/sh non-interactively,
    # those subshells never source /etc/profile.d, and numpy's
    # _umath_linalg.dll (which is reachable from removelines + uniformize,
    # both Python helpers in solve-field's pipeline) fails to load with
    # "ImportError: No such file or directory" because cyglapack-0.dll
    # cannot be found. Putting the dir on the *machine* PATH means every
    # process started after this provider runs inherits it, login shell or
    # not.
    ${lapackDir} = Join-Path ${CygwinRoot} 'lib\lapack'
    if (Test-Path ${lapackDir}) {
        Add-ToSystemPath -Dir ${lapackDir}
        Write-Host "Added ${lapackDir} to system PATH (cyglapack-0.dll discovery)."
    }

    # Run any pending Cygwin postinstall scripts that the new packages queued.
    # This is the same pattern used by provide-cygwin.ps1 and is what runs
    # peflagsall / rebaseall / passwd-grp / etc. Skipping this step leaves DLLs
    # at random ASLR addresses and breaks Cygwin's fork() emulation (see
    # 'child_info_fork::abort: Loaded to different address' in cygwin.com FAQ).
    Write-Host "Running Cygwin postinstall scripts ..."
    & ${bashExe} -lc @'
set -e
shopt -s nullglob
for f in /etc/postinstall/*.sh; do
  /usr/bin/dash "$f" || exit 1
  mv "$f" "$f.done"
done
exit 0
'@
    if ($LASTEXITCODE -ne 0) {
        throw "Cygwin postinstall scripts failed (exit ${LASTEXITCODE})."
    }

    # Install the bundled fitsio Python wheel. astrometry's util/fits.py
    # imports fitsio (preferred backend) or astropy.io.fits or pyfits at
    # runtime; without one, removelines/uniformize raise
    # "'NoPyfits' object has no attribute 'open'" mid-pipeline. fitsio is
    # not packaged for Cygwin, and pip-building it from PyPI on a target
    # would require gcc + cfitsio-devel + numpy build deps and would also
    # need to be online. We pre-build the wheel against the system
    # cygcfitsio-10.dll once (see DEPENDENCIES.md "Building the fitsio
    # wheel") and ship it as a provider asset so install is offline and
    # deterministic.
    ${fitsioWheel} = Get-ChildItem ${AssetsRoot} -Filter 'fitsio-*-cp39-cp39-cygwin_*_x86_64.whl' `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq ${fitsioWheel}) {
        throw "fitsio wheel not found in assets/; expected fitsio-*-cp39-cp39-cygwin_*.whl"
    }
    Write-Host ("Installing bundled fitsio wheel: {0} ..." -f ${fitsioWheel}.Name)
    # Translate the Windows path to a Cygwin path via cygpath, then pip-install.
    & ${bashExe} -lc ("python3 -m pip install --quiet --no-warn-script-location --no-deps --no-index ""$(cygpath -u '{0}')""" `
        -f ${fitsioWheel}.FullName)
    if ($LASTEXITCODE -ne 0) {
        throw "pip install of bundled fitsio wheel failed (exit ${LASTEXITCODE})."
    }
    # Confirm the import works after install.
    & ${bashExe} -lc 'python3 -c "import fitsio; import sys; sys.exit(0 if fitsio.__version__ else 1)"'
    if ($LASTEXITCODE -ne 0) {
        throw "fitsio installed but cannot be imported (exit ${LASTEXITCODE})."
    }
    Write-Host "fitsio installed and importable."

    # Verification: spot-check that the key runtime DLLs landed in C:\cygwin64\bin.
    ${verifyDir} = Get-MastVerifyDir
    Confirm-Dir ${verifyDir}
    ${verifyLog} = Join-Path ${verifyDir} 'astrometry-dependencies-verify.log'
    ${required} = @(
        'cygcfitsio-10.dll','cygwcs-4.dll','cygnetpbm-10.dll',
        'cygcairo-2.dll','cygpng16-16.dll','cygjpeg-8.dll',
        'cygcurl-4.dll','libpython3.9.dll'
    )
    ${binDir} = Join-Path ${CygwinRoot} 'bin'
    ${missing} = @()
    foreach (${d} in ${required}) {
        if (-not (Test-Path (Join-Path ${binDir} ${d}))) { ${missing} += ${d} }
    }
    if (${missing}.Count -gt 0) {
        ("FAIL: missing DLLs after setup.exe: {0}" -f (${missing} -join ', ')) `
            | Out-File -FilePath ${verifyLog} -Encoding UTF8
        throw "Expected runtime DLLs missing after install: $(${missing} -join ', ')"
    }
    "All astrometry runtime DLLs present in ${binDir}" `
        | Out-File -FilePath ${verifyLog} -Encoding UTF8

    # Smoke marker
    Set-Content -Path (Join-Path (Get-MastSmokeDir) 'astrometry-dependencies-smoke.txt') `
        -Value 'astrometry_deps_ok' -Encoding ASCII
    Write-Host "Astrometry Cygwin dependencies installed and verified."
}
finally {
    Stop-ProvisionLog
}
exit 0
