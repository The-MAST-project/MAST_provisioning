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

    ${setupArgs} = @(
        '--quiet-mode',
        '--no-shortcuts','--no-desktop','--no-startmenu','--no-write-registry',
        '--upgrade-also',
        '--root', ${CygwinRoot},
        '--site', ${MirrorSite},
        '--proxy', ${ProxyHost},
        '--local-package-dir', ${pkgCache},
        '--packages', ${Packages}
    )

    Write-Host "Running ${setupPath} for packages: ${Packages}"
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
