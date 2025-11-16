param(
    [string]${AssetsRoot} = ".",
    [string]${InstallRoot} = "C:\Program Files\Microsoft VS Code"
)

${ErrorActionPreference} = "Stop"
${logDir} = Join-Path ${env:ProgramData} "MAST\logs"
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "vscode-install.log"

try {
    Write-Host "Starting VSCode installation..."

    ${installerPath} = Join-Path ${AssetsRoot} "VSCodeSetup-x64.exe"
    if (-not (Test-Path ${installerPath})) {
        throw "VSCode installer not found at ${installerPath}"
    }

    Write-Host "Running VSCode installer: ${installerPath}"
    & ${installerPath} /S /D=${InstallRoot} 2>&1 | Tee-Object -FilePath ${logFile}

    if (${LASTEXITCODE} -ne 0) {
        throw "VSCode installer exited with code ${LASTEXITCODE}"
    }

    # Verify installation
    ${vscodeExe} = Join-Path ${InstallRoot} "Code.exe"
    if (-not (Test-Path ${vscodeExe})) {
        throw "VSCode executable not found after installation at ${vscodeExe}"
    }

    Write-Host "VSCode installation completed successfully" | Tee-Object -FilePath ${logFile} -Append
    exit 0
}
catch {
    ${errorMsg} = "VSCode installation failed: $_"
    Write-Host ${errorMsg}
    ${errorMsg} | Out-File -FilePath ${logFile} -Append -Encoding UTF8
    exit 1
}
