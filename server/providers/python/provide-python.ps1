#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]${AssetsRoot} = ${PSScriptRoot},
    [string]${Installer}  = "python-3.12.0-amd64.exe",
    [string]${InstallDir} = "C:\Python312"
)

# --- Import shared helpers ---
try {
    ${provLocal}  = Join-Path ${PSScriptRoot} 'provisioning.psm1'
    ${provGlobal} = 'C:\ProgramData\MAST\provisioning.psm1'
    if (Test-Path ${provLocal}) {
        Import-Module ${provLocal} -Force -ErrorAction Stop
    }
    elseif (Test-Path ${provGlobal}) {
        Import-Module ${provGlobal} -Force -ErrorAction Stop
    }
    else {
        throw "provisioning.psm1 not found next to script or in ${provGlobal}"
    }
}
catch {
    throw "Failed to import provisioning.psm1: $($_.Exception.Message)"
}

${log} = Start-ProvisionLog -Component 'provide-python'
try {
    # --- Locate installer ---
    ${exePath} = Join-Path (Join-Path ${AssetsRoot} 'assets') ${Installer}
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
    & ${pythonExe} -m ensurepip --default-pip | Out-Null

    # --- Upgrade pip (optional but good practice) ---
    & ${pythonExe} -m pip install --upgrade pip | Out-Null

    # --- Install virtualenv ---
    Write-Host "Installing virtualenv ..."
    & ${pythonExe} -m pip install virtualenv | Out-Null

    # --- Verify installation ---
    try {
        ${verPy} = & ${pythonExe} --version
        ${verVenv} = & ${pythonExe} -m virtualenv --version
        Write-Host "Python version: ${verPy}"
        Write-Host "virtualenv version: ${verVenv}"
        ${verPy} + "`n" + ${verVenv} | Out-File -FilePath (Join-Path ${env:ProgramData} 'MAST\logs\python-verify.log') -Encoding UTF8
    }
    catch {
        Write-Warning "Verification failed: $($_.Exception.Message)"
    }
}
finally {
    Stop-ProvisionLog
}
exit 0
