param(
    [string]${AssetsRoot} = ".",
    [string]${InstallRoot} = "C:\Program Files (x86)\PHDGuiding2"
)

${ErrorActionPreference} = "Stop"
${logDir} = Join-Path ${env:ProgramData} "MAST\logs"
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "phd2-install.log"

try {
    Write-Host "Starting PHD2 installation..."
    ${installerPath} = Join-Path ${AssetsRoot} "phd2-x64-2.6.13dev7mast04-installer.exe"
    if (-not (Test-Path ${installerPath})) {
        throw "PHD2 installer not found at ${installerPath}"
    }

    Write-Host "Running PHD2 installer: ${installerPath}"
    & ${installerPath} /VERYSILENT 2>&1 | Tee-Object -FilePath ${logFile}

    if (${LASTEXITCODE} -ne 0) {
        throw "PHD2 installer exited with code ${LASTEXITCODE}"
    }

    # Verify installation
    ${phd2Exe} = Join-Path ${InstallRoot} "phd2.exe"
    if (-not (Test-Path ${phd2Exe})) {
        throw "PHD2 executable not found after installation at ${phd2Exe}"
    }

    Write-Host "PHD2 installation completed successfully" | Tee-Object -FilePath ${logFile} -Append
    exit 0
}
catch {
    ${errorMsg} = "PHD2 installation failed: $_"
    Write-Host ${errorMsg}
    ${errorMsg} | Out-File -FilePath ${logFile} -Append -Encoding UTF8
    exit 1
}
