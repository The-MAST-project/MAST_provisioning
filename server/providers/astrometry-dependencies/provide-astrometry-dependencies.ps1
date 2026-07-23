#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]${AssetsRoot}  = ${PSScriptRoot},
    [string]${CygwinRoot}  = 'C:\cygwin64',
    # The mirror URL the frozen package cache was originally downloaded from.
    # With --local-install nothing is fetched from it: setup-x86_64.exe only
    # uses it to select the matching URL-encoded subfolder inside the cache
    # tree. Must match the mirror the cache was harvested from (see
    # build/harvest-cygwin-cache.ps1).
    [string]${MirrorSite}  = 'https://cygwin.itefix.net',
    [string]${SetupName}   = 'setup-x86_64.exe',
    # Re-run setup-x86_64.exe + pip even if the astrometry runtime DLLs are
    # already present (otherwise an already-satisfied unit is left as-is).
    [switch]${Force}
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

# Idempotent skip: if every astrometry runtime DLL is already present in the
# cygwin bin dir (the exact set verify checks), the offline setup-x86_64.exe
# package install + pip wheel have nothing to do. Use -Force to re-run.
${_reqDlls} = @('cygcfitsio-10.dll','cygwcs-4.dll','cygnetpbm-10.dll','cygcairo-2.dll','cygpng16-16.dll','cygjpeg-8.dll','cygcurl-4.dll','libpython3.9.dll')
${_binDir}  = Join-Path ${CygwinRoot} 'bin'
${_missing} = @(${_reqDlls} | Where-Object { -not (Test-Path (Join-Path ${_binDir} $_)) })
if (-not ${Force} -and ${_missing}.Count -eq 0) {
    Write-Host "astrometry runtime DLLs already present in ${_binDir}; skipping setup-x86_64.exe + pip. Use -Force to re-run."
    exit 0
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

    # Frozen offline package cache, staged into the payload by build-mast.ps1
    # from the build-host vendor path C:\MAST\cygwin-pkg-cache (see issue #20
    # and docs/cygwin-freeze-plan.md). The install is FULLY OFFLINE
    # (--local-install): setup-x86_64.exe reads packages from this cache and
    # never touches the network, so the installed cygwin is deterministic
    # (3.6.9, matching the bundled fitsio wheel tag) regardless of what the
    # live itefix mirror currently serves. This also removes every proxy
    # concern the online install needed (setup.rc net-method, --proxy,
    # WinINet cert-revocation posture) -- they were download-only.
    ${pkgCache} = Join-Path ${AssetsRoot} 'cygwin-pkg-cache'
    if (-not (Test-Path -LiteralPath ${pkgCache})) {
        throw "Frozen cygwin package cache not staged at ${pkgCache}. The build host must populate C:\MAST\cygwin-pkg-cache once (build/harvest-cygwin-cache.ps1) and build-mast.ps1 stages it."
    }
    ${cacheIni} = @(Get-ChildItem -LiteralPath ${pkgCache} -Filter 'setup.ini' -File -Recurse -ErrorAction SilentlyContinue)
    if (${cacheIni}.Count -eq 0) {
        throw "Staged cygwin package cache at ${pkgCache} holds no setup.ini; re-harvest it (build/harvest-cygwin-cache.ps1 -Force)."
    }

    Write-Host "==================================================================="
    Write-Host  "[astrometry-deps] *** OFFLINE MODE (frozen package cache) ***"
    Write-Host "==================================================================="

    # --site does not download anything under --local-install; it only selects
    # the matching URL-encoded mirror subfolder inside the cache tree.
    ${setupArgs} = @(
        '--quiet-mode',
        '--no-shortcuts','--no-desktop','--no-startmenu','--no-write-registry',
        '--local-install',
        '--root', ${CygwinRoot},
        '--site', ${MirrorSite},
        '--local-package-dir', ${pkgCache},
        '--packages', ${Packages}
    )

    Write-Host ("Running ${setupPath} offline for packages: ${Packages} (cache: {0})" -f ${pkgCache})
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
    # Strip CR before handing the script to bash: if this .ps1 is checked out
    # CRLF (Windows core.autocrlf), the here-string carries \r into bash, which
    # fails with "syntax error near $'do\r'". Normalizing to LF makes this step
    # immune to the file's line endings.
    ${postinstallSh} = @'
set -e
shopt -s nullglob
for f in /etc/postinstall/*.sh; do
  /usr/bin/dash "$f" || exit 1
  mv "$f" "$f.done"
done
exit 0
'@
    & ${bashExe} -lc (${postinstallSh} -replace "`r", "")
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
    # Translate the Windows path to a Cygwin /cygdrive path IN POWERSHELL. Do NOT
    # use "$(cygpath -u ...)" inside the bash string: that $(...) is a PowerShell
    # subexpression, so PowerShell runs `cygpath` on the *host* (it isn't on the
    # host PATH -> CommandNotFoundException) and the wheel path never reaches pip.
    # That bug shipped a unit with fitsio NOT installed, so astrometry's
    # removelines/util.fits fell back to the NoPyfits stub and every solve died
    # with "'NoPyfits' object has no attribute 'open'". See DECISIONS.md 2026-05-27.
    ${wheelWin} = ${fitsioWheel}.FullName
    ${wheelCyg} = '/cygdrive/' + (${wheelWin}.Substring(0,1).ToLower()) + ((${wheelWin}.Substring(2)) -replace '\\','/')
    & ${bashExe} -lc ("python3 -m pip install --quiet --no-warn-script-location --no-deps --no-index '{0}'" -f ${wheelCyg})
    if ($LASTEXITCODE -ne 0) {
        throw "pip install of bundled fitsio wheel failed (exit ${LASTEXITCODE})."
    }
    # Confirm the import works after install. Quoting note: an earlier version of
    # this line used PS single-quote outer + double-quote inner around the
    # `python3 -c "..."` argument:
    #     & ${bashExe} -lc 'python3 -c "import fitsio; ..."'
    # In Windows PowerShell 5.1, that strips the embedded double quotes when
    # building the native-process command line, so bash sees
    # `python3 -c import fitsio; ...` and python runs `-c import` -> SyntaxError
    # at "<string>", line 1. Flip the nesting: PS double-quote outer (no
    # interpolation hazards here since we use no `$` vars inside) wrapping a
    # bash single-quoted python script. Single quotes survive the PS->native
    # boundary verbatim and bash forwards them to python intact.
    & ${bashExe} -lc "python3 -c 'import fitsio, sys; sys.exit(0 if fitsio.__version__ else 1)'"
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
