#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]${AssetsRoot}  = ${PSScriptRoot},
    [string]${ArchiveName} = 'cygwin64-clean.tgz',
    [string]${InstallRoot} = 'C:\cygwin64',
    # Reinstall even if a healthy Cygwin is already present (re-extract + mirror +
    # re-run postinstall). Without it, an existing healthy install is left as-is.
    [switch]${Force}
)

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

# --- Idempotent skip: leave an already-healthy Cygwin in place ---------------
# A full provision re-extracts the tgz, robocopy /MIR's the whole tree into
# ${InstallRoot}, and re-runs every /etc/postinstall/*.sh -- minutes of work,
# and re-running postinstall has caused hangs/drains before. If Cygwin is
# already installed and bash actually runs, there is nothing to do; we only
# re-assert PATH and refresh the verify log + smoke marker. Use -Force to
# deliberately reinstall.
${bashExeExisting} = Join-Path ${InstallRoot} 'bin\bash.exe'
if (-not ${Force} -and (Test-Path ${bashExeExisting})) {
    ${uname} = & ${bashExeExisting} -lc 'uname -a' 2>$null
    if (${LASTEXITCODE} -eq 0 -and ${uname}) {
        Write-Host ("Cygwin already installed and healthy at {0} ({1}); skipping extract/mirror/postinstall. Use -Force to reinstall." -f ${InstallRoot}, ${uname})
        Add-ToSystemPath -Dir (Join-Path ${InstallRoot} 'bin')
        ${verifyLogSkip} = Join-Path (Get-MastVerifyDir) 'cygwin-verify.log'
        Confirm-Dir (Split-Path ${verifyLogSkip} -Parent)
        ("{0}" -f ${uname}) | Out-File -FilePath ${verifyLogSkip} -Encoding UTF8
        '(skipped reinstall: existing healthy Cygwin)' | Out-File -FilePath ${verifyLogSkip} -Append -Encoding UTF8
        Set-Content -Path (Join-Path (Get-MastSmokeDir) 'cygwin-smoke.txt') -Value 'cygwin_ok' -Encoding ASCII
        exit 0
    }
    Write-Host ("Cygwin present at {0} but 'uname' failed (exit={1}); reinstalling." -f ${InstallRoot}, ${LASTEXITCODE})
}

${log} = Start-ProvisionLog -Component 'provide-cygwin'
try {
    # --- Locate archive ---
    ${archivePath} = Join-Path ${AssetsRoot} ${ArchiveName}
    if (-not (Test-Path ${archivePath})) {
        throw "Cygwin archive not found: ${archivePath}"
    }

    # --- Stage extraction to a temp folder ---
    ${stage} = Join-Path ${env:TEMP} ("cygwin_stage_{0:yyyyMMdd_HHmmss}" -f (Get-Date))
    Confirm-Dir ${stage}

    Write-Host "Extracting ${archivePath} to staging ${stage} ..."
    # Expand-AnyArchive should handle .zip, .7z, .tar.gz/.tgz per your provisioning.psm1
    Expand-AnyArchive -ArchivePath ${archivePath} -Destination ${stage}

    # The tgz may contain a top-level "cygwin64" folder or the tree directly.
    # Resolve the source folder that actually contains /bin, /etc, etc.
    ${candidate} = Join-Path ${stage} 'cygwin64-clean'
    if (Test-Path ${candidate} -PathType Container) {
        ${srcRoot} = ${candidate}
    }
    else {
        ${srcRoot} = ${stage}
    }

    # --- Install to target root ---
    Write-Host "Syncing Cygwin files into ${InstallRoot} ..."
    Confirm-Dir ${InstallRoot}
    # Use robocopy for speed and ACLs; mirrors content
    robocopy "${srcRoot}" "${InstallRoot}" /MIR /R:1 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null

    # --- Ensure bin is on the System PATH ---
    ${binDir} = Join-Path ${InstallRoot} 'bin'
    Add-ToSystemPath -Dir ${binDir}

    # --- Run Cygwin postinstall scripts (once) ---
    ${bashExe} = Join-Path ${binDir} 'bash.exe'
    if (-not (Test-Path ${bashExe})) {
        throw "bash.exe not found at ${bashExe}"
    }

    # Execute any pending /etc/postinstall/*.sh (rename to .done after success).
    # Run inline, but strip CR first: if this .ps1 is checked out CRLF (Windows
    # core.autocrlf), the here-string carries \r into bash and fails with
    # "syntax error near $'do\r'". Normalizing to LF makes it EOL-immune.
    Write-Host "Running Cygwin postinstall scripts ..."
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

    # --- Verification: print versions and a simple command ---
    Write-Host "Verifying Cygwin ..."
    ${verifyLog} = Join-Path (Get-MastVerifyDir) 'cygwin-verify.log'
    Confirm-Dir (Split-Path ${verifyLog} -Parent)

    # Capture uname, which, and cygcheck versions
    & ${bashExe} -lc 'uname -a'           | Out-File -FilePath ${verifyLog} -Encoding UTF8
    & ${bashExe} -lc 'which bash; which tar; which gzip' | Out-File -FilePath ${verifyLog} -Append -Encoding UTF8
    & ${bashExe} -lc 'cygcheck -V'        | Out-File -FilePath ${verifyLog} -Append -Encoding UTF8

    # Smoke marker
    Set-Content -Path (Join-Path (Get-MastSmokeDir) 'cygwin-smoke.txt') -Value 'cygwin_ok' -Encoding ASCII

    Write-Host "Cygwin installed to ${InstallRoot}. PATH updated. Verification log at ${verifyLog}."
    # Astrometry.net is now staged by the dedicated 'astrometry' provider (order 500),
    # which runs after 'astrometry-dependencies' (order 400) installs cfitsio/wcs/etc.
}
finally {
    Stop-ProvisionLog
}
exit 0
