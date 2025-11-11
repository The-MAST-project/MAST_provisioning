param(
    [string]${AssetsRoot} = "."
)

${ErrorActionPreference} = "Stop"
${logDir} = Join-Path ${env:ProgramData} "MAST\logs"
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "zwo-install.log"

try {
    Write-Host "Starting ZWO camera driver installation..."

    # Install ZWO ASI Camera Drivers
    ${asiDriverPath} = Join-Path ${AssetsRoot} "assets\ZWO_ASI_Cameras_driver_Setup_V3.25.exe"
    if (-not (Test-Path ${asiDriverPath})) {
        throw "ZWO ASI camera driver not found at ${asiDriverPath}"
    }

    Write-Host "Installing ZWO ASI Camera Drivers..." | Tee-Object -FilePath ${logFile}
    & ${asiDriverPath} /S 2>&1 | Tee-Object -FilePath ${logFile} -Append

    if (${LASTEXITCODE} -ne 0) {
        throw "ZWO ASI camera driver installer exited with code ${LASTEXITCODE}"
    }

    # Install ZWO ASCOM Drivers
    ${ascomPath} = Join-Path ${AssetsRoot} "assets\ZWO_ASCOM_Setup_V6.5.32.exe"
    if (-not (Test-Path ${ascomPath})) {
        throw "ZWO ASCOM driver not found at ${ascomPath}"
    }

    Write-Host "Installing ZWO ASCOM Drivers..." | Tee-Object -FilePath ${logFile} -Append
    & ${ascomPath} /S 2>&1 | Tee-Object -FilePath ${logFile} -Append

    if (${LASTEXITCODE} -ne 0) {
        throw "ZWO ASCOM driver installer exited with code ${LASTEXITCODE}"
    }

    # Install ASI Studio
    ${asiStudioPath} = Join-Path ${AssetsRoot} "assets\ASIStudio_V1.16.2_x64_Setup.exe"
    if (-not (Test-Path ${asiStudioPath})) {
        throw "ASI Studio installer not found at ${asiStudioPath}"
    }

    Write-Host "Installing ASI Studio..." | Tee-Object -FilePath ${logFile} -Append
    & ${asiStudioPath} /S 2>&1 | Tee-Object -FilePath ${logFile} -Append

    if (${LASTEXITCODE} -ne 0) {
        throw "ASI Studio installer exited with code ${LASTEXITCODE}"
    }

    # Verify installation
    ${asiStudioExe} = "C:\Program Files\ASI Studio\ASIStudio.exe"
    if (-not (Test-Path ${asiStudioExe})) {
        throw "ASI Studio executable not found after installation at ${asiStudioExe}"
    }

    Write-Host "ZWO installation completed successfully" | Tee-Object -FilePath ${logFile} -Append
    exit 0
}
catch {
    ${errorMsg} = "ZWO installation failed: $_"
    Write-Host ${errorMsg}
    ${errorMsg} | Out-File -FilePath ${logFile} -Append -Encoding UTF8
    exit 1
}
