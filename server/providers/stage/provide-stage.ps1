param(
    [string]${AssetsRoot} = ".",
    [string]${InstallRoot} = "C:\Program Files\Stage"
)

${ErrorActionPreference} = "Stop"
${logDir} = Join-Path ${env:ProgramData} "MAST\logs"
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "stage-install.log"

try {
    Write-Host "Starting Stage installation..."

    ${installerPath} = Join-Path ${AssetsRoot} "assets\stage-installer.exe"
    if (-not (Test-Path ${installerPath})) {
        throw "Stage installer not found at ${installerPath}"
    }

    Write-Host "Running Stage installer: ${installerPath}"
    & ${installerPath} /S /D=${InstallRoot} 2>&1 | Tee-Object -FilePath ${logFile}

    if (${LASTEXITCODE} -ne 0) {
        throw "Stage installer exited with code ${LASTEXITCODE}"
    }

    # Verify installation
    ${stageExe} = Join-Path ${InstallRoot} "stage.exe"
    if (-not (Test-Path ${stageExe})) {
        throw "Stage executable not found after installation at ${stageExe}"
    }

    Write-Host "Stage installation completed successfully" | Tee-Object -FilePath ${logFile} -Append
    exit 0
}
catch {
    ${errorMsg} = "Stage installation failed: $_"
    Write-Host ${errorMsg}
    ${errorMsg} | Out-File -FilePath ${logFile} -Append -Encoding UTF8
    exit 1
}
