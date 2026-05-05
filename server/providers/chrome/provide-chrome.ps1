param(
    [string]${AssetsRoot} = "."
)

${ErrorActionPreference} = "Stop"
${logDir} = Join-Path ${env:ProgramData} "MAST\logs"
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "chrome-install.log"

try {
    Write-Host "Starting Chrome installation..."

    ${installerPath} = Join-Path ${AssetsRoot} "ChromeSetup.exe"
    if (-not (Test-Path ${installerPath})) {
        throw "Chrome installer not found at ${installerPath}"
    }

    Write-Host "Running Chrome installer: ${installerPath}"
    & ${installerPath} /silent /install 2>&1 | Tee-Object -FilePath ${logFile}

    if (${LASTEXITCODE} -ne 0) {
        throw "Chrome installer exited with code ${LASTEXITCODE}"
    }

    # Verify installation
    ${chromeExe} = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    if (-not (Test-Path ${chromeExe})) {
        throw "Chrome executable not found after installation at ${chromeExe}"
    }

    Write-Host "Chrome installation completed successfully" | Tee-Object -FilePath ${logFile} -Append
    exit 0
}
catch {
    ${errorMsg} = "Chrome installation failed: $_"
    Write-Host ${errorMsg}
    ${errorMsg} | Out-File -FilePath ${logFile} -Append -Encoding UTF8
    exit 1
}
