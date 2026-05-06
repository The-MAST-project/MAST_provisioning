#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]${AssetsRoot}  = ${PSScriptRoot},
    [string]${ArchiveName} = 'cygwin64-clean.tgz',
    [string]${AstrometryArchiveName} = 'astrometry.tgz',
    [string]${InstallRoot} = 'C:\cygwin64'
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

    # Execute any pending /etc/postinstall/*.sh (rename to .done after success)
    Write-Host "Running Cygwin postinstall scripts ..."
    ${postInstallCmd} = @'
set -e
shopt -s nullglob
for f in /etc/postinstall/*.sh; do
  /usr/bin/dash "$f" || exit 1
  mv "$f" "$f.done"
done
exit 0
'@

    # Run inside Cygwin.
    # Write to a Windows path, then convert to a Cygwin path via cygpath so
    # bash can locate the file (bash cannot resolve Windows-style paths directly).
    ${tmpScript} = Join-Path ${env:TEMP} "cygwin_postinstall_$(Get-Random).sh"
    Set-Content -Path ${tmpScript} -Value ${postInstallCmd} -Encoding ASCII
    # Cygwin -lc login shell emits skeleton-file messages before the cygpath output;
    # take only the last line which is the actual converted path.
    ${cygTmp} = ((& ${bashExe} -lc "cygpath -u '$($tmpScript -replace '\\','/')'") | Select-Object -Last 1).Trim()
    & ${bashExe} -lc "dos2unix '$cygTmp' 2>/dev/null; chmod +x '$cygTmp' && bash '$cygTmp'"
    Remove-Item -Force ${tmpScript} -ErrorAction SilentlyContinue

    # --- Verification: print versions and a simple command ---
    Write-Host "Verifying Cygwin ..."
    ${verifyLog} = Join-Path ${env:ProgramData} 'MAST\logs\cygwin-verify.log'
    Confirm-Dir (Split-Path ${verifyLog} -Parent)

    # Capture uname, which, and cygcheck versions
    & ${bashExe} -lc 'uname -a'           | Out-File -FilePath ${verifyLog} -Encoding UTF8
    & ${bashExe} -lc 'which bash; which tar; which gzip' | Out-File -FilePath ${verifyLog} -Append -Encoding UTF8
    & ${bashExe} -lc 'cygcheck -V'        | Out-File -FilePath ${verifyLog} -Append -Encoding UTF8

    # Smoke marker
    Set-Content -Path (Join-Path ${env:ProgramData} 'MAST\logs\cygwin-smoke.txt') -Value 'cygwin_ok' -Encoding ASCII

    Write-Host "Cygwin installed to ${InstallRoot}. PATH updated. Verification log at ${verifyLog}."

    Write-Host "Expanding Astrometry.net ..."
    Expand-AnyArchive -ArchivePath ${astrometryArchivePath} -Destination "C:\cygwin64\usr\local\astrometry"
    Write-Host "Astrometry.net expanded."
}
finally {
    Stop-ProvisionLog
}
exit 0
