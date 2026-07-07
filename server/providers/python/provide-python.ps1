#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]${AssetsRoot} = ${PSScriptRoot},
    [string]${Installer}  = "python-3.12.2-amd64.exe",
    [string]${InstallDir} = "C:\Python312",
    # Reinstall even if Python + virtualenv are already present (otherwise the
    # existing install is left as-is; installer + pip/virtualenv chain is skipped).
    [switch]${Force}
)

# --- Import shared helpers ---
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

# Idempotent skip: if Python is installed AND virtualenv works (the full state
# this provider produces, and what verify checks), skip the installer + the
# pip/virtualenv chain. Only re-assert PATH. Use -Force to reinstall.
${pythonExeGuard} = Join-Path ${InstallDir} 'python.exe'
if (-not ${Force} -and (Test-Path ${pythonExeGuard})) {
    & ${pythonExeGuard} -m virtualenv --version *>$null
    if (${LASTEXITCODE} -eq 0) {
        Add-ToSystemPath -Dir ${InstallDir}
        Write-Host "Python + virtualenv already installed at ${InstallDir}; skipping installer. Use -Force to reinstall."
        exit 0
    }
}

${log} = Start-ProvisionLog -Component 'provide-python'
try {
    # --- Locate installer ---
    ${exePath} = Join-Path ${AssetsRoot} ${Installer}
    if (-not (Test-Path ${exePath})) {
        throw "Python installer not found: ${exePath}"
    }

    # --- Install Python silently ---
    Write-Host "Installing Python 3.12.0 ..."
    ${installer_args} = "/quiet InstallAllUsers=1 PrependPath=1 TargetDir=`"${InstallDir}`" Include_test=0 Include_doc=0"
    Invoke-Exe -FilePath ${exePath} -Arguments ${installer_args} -Tag "python-install"

    # --- Verify python.exe exists ---
    ${pythonExe} = Join-Path ${InstallDir} 'python.exe'
    if (-not (Test-Path ${pythonExe})) {
        Write-Warning "python.exe not found in ${InstallDir}; installation may have failed."
    }
    else {
        Add-ToSystemPath -Dir ${InstallDir}
        Write-Host "Python installed at ${InstallDir} and added to PATH."
    }

    # --- Ensure pip is present ---
    Write-Host "Ensuring pip is available ..."
    ${env:PIP_NO_WARN_SCRIPT_LOCATION} = '1'
    & ${pythonExe} -m ensurepip --default-pip | Out-Null

    # --- Upgrade pip (optional but good practice) ---
    & ${pythonExe} -m pip install --upgrade pip --disable-pip-version-check *>$null

    # --- Install virtualenv ---
    Write-Host "Installing virtualenv ..."
    & ${pythonExe} -m pip install virtualenv --disable-pip-version-check *>$null

    # --- Verify installation ---
    try {
        ${verPy} = & ${pythonExe} --version
        ${verVenv} = & ${pythonExe} -m virtualenv --version
        Write-Host "Python version: ${verPy}"
        Write-Host "virtualenv version: ${verVenv}"
        ${verPy} + "`n" + ${verVenv} | Out-File -FilePath (Join-Path (Get-MastVerifyDir) 'python-verify.log') -Encoding UTF8
    }
    catch {
        Write-Warning "Verification failed: $($_.Exception.Message)"
    }
}
finally {
    Stop-ProvisionLog
}
exit 0
