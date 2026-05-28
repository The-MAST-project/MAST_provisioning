#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]${AssetsRoot}  = ${PSScriptRoot},
    [string]${CygwinRoot}  = 'C:\cygwin64',
    [string]${MirrorSite}  = 'https://cygwin.itefix.net',
    [string]${ProxyHost}   = 'bcproxy.weizmann.ac.il:8080',
    [string]${SetupName}   = 'setup-x86_64.exe',
    # Explicit proxy mode for setup-x86_64.exe. Defaults to 'use' (matching
    # the provider-level default in provide-proxy.ps1 and the common case of
    # a unit inside the Weizmann campus network). build-mast.ps1 -ProxyMode
    # flips this to 'direct' for runs against a unit that cannot reach
    # bcproxy (off-campus, no VPN, etc.) -- independent of whether the run
    # itself is a dev/test or a prod cycle.
    #
    # 'direct' is NOT the same as "just don't pass --proxy". setup-x86_64.exe
    # defaults to IE5 net-method which does WinINet+WPAD autodiscovery and
    # can still pick up a proxy even when HKCU ProxyEnable=0 -- which is why
    # earlier runs saw `net: Proxy` and 12007 errors despite the proxy
    # provider correctly clearing every other surface. The conclusive fix:
    # pre-write setup.rc with net-method=Direct so setup.exe skips IE5
    # entirely.
    [ValidateSet('use','direct')]
    [string]${ProxyMode}   = 'use'
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

# Shared WinINet posture helpers (best-effort cert revocation through bcproxy).
${_netDot} = Join-Path ${PSScriptRoot} 'mast-net.ps1'
if (-not (Test-Path ${_netDot})) { ${_netDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-net.ps1' }
. ${_netDot}

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

    # Explicit proxy mode (no probing). See -ProxyMode param-block comment
    # for the rationale; tl;dr setup-x86_64.exe with no --proxy defaults to
    # IE5 net-method and finds a proxy via WPAD even when HKCU ProxyEnable=0,
    # so "just clear env vars" is not enough -- we must positively tell
    # setup.exe which net-method to use via setup.rc.
    ${useProxy} = (${ProxyMode} -eq 'use')
    ${modeBanner} = if (${useProxy}) { '*** WEIZMANN-PROXY MODE ***' } else { '*** NO-WEIZMANN-PROXY (DIRECT) MODE ***' }
    Write-Host "==================================================================="
    Write-Host ("[astrometry-deps] {0}" -f ${modeBanner})
    Write-Host "==================================================================="

    # Pre-write <root>\etc\setup\setup.rc with the chosen net-method. Format
    # matches what setup-x86_64.exe itself writes: key on one line, value
    # on the next line, blank line between records. setup.exe reads this
    # at startup before any CLI parsing, so it overrides the IE5 default.
    ${setupRcDir}  = Join-Path ${CygwinRoot} 'etc\setup'
    Confirm-Dir ${setupRcDir}
    ${setupRcPath} = Join-Path ${setupRcDir} 'setup.rc'
    ${netMethod}   = if (${useProxy}) { 'Proxy' } else { 'Direct' }
    ${rcLines} = @(
        'last-cache',
        ${pkgCache},
        '',
        'net-method',
        ${netMethod},
        ''
    )
    if (${useProxy}) {
        ${rcLines} += @('http-proxy', ${ProxyHost}, '')
        ${rcLines} += @('ftp-proxy',  ${ProxyHost}, '')
    }
    Set-Content -LiteralPath ${setupRcPath} -Encoding ASCII -Value (${rcLines} -join "`n")
    Write-Host ("Wrote setup.rc with net-method={0} to {1}" -f ${netMethod}, ${setupRcPath})

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

    # setup-x86_64.exe fetches over HTTPS via WinINet and HARD-fails the TLS
    # handshake (error 12057) when the server-cert revocation check cannot
    # complete -- which is the case through bcproxy, where CryptoAPI's cryptnet
    # CRL/OCSP retrieval returns 0x80070057. Make revocation best-effort (the
    # same posture git uses) for the duration of the setup.exe run only, then
    # restore. See mast-net.ps1 / DECISIONS.md 2026-05-27.
    ${prevRev} = Disable-WinINetCertRevocationCheck
    Write-Host ("[astrometry-deps] WinINet server-cert revocation set best-effort for setup.exe (prev={0})." -f $(if ($null -eq ${prevRev}) { 'unset' } else { ${prevRev} }))
    try {
        ${proc} = Start-Process -FilePath ${setupPath} -ArgumentList ${setupArgs} `
            -Wait -PassThru -NoNewWindow
        try { ${proc}.Refresh() } catch {}
        ${exit} = ${proc}.ExitCode
    } finally {
        Restore-WinINetCertRevocationCheck -Previous ${prevRev}
        Write-Host "[astrometry-deps] WinINet server-cert revocation check restored."
    }
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
