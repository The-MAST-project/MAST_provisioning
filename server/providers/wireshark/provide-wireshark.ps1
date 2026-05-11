param(
    [string]${AssetsRoot} = ".",
    [string]${InstallRoot} = "C:\Program Files\Wireshark"
)

${ErrorActionPreference} = "Stop"
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "wireshark-install.log"

try {
    Write-Host "Starting Wireshark installation..."

    ${installerPath} = Join-Path ${AssetsRoot} "Wireshark-4.6.0-x64.exe"
    if (-not (Test-Path ${installerPath})) {
        throw "Wireshark installer not found at ${installerPath}"
    }

    Write-Host "Running Wireshark installer: ${installerPath}"
    & ${installerPath} /S /D=${InstallRoot} 2>&1 | Tee-Object -FilePath ${logFile}

    if (${LASTEXITCODE} -ne 0) {
        throw "Wireshark installer exited with code ${LASTEXITCODE}"
    }

    # Verify installation
    ${wiresharkExe} = Join-Path ${InstallRoot} "wireshark.exe"
    if (-not (Test-Path ${wiresharkExe})) {
        throw "Wireshark executable not found after installation at ${wiresharkExe}"
    }

    Write-Host "Wireshark installation completed successfully" | Tee-Object -FilePath ${logFile} -Append
    exit 0
}
catch {
    ${errorMsg} = "Wireshark installation failed: $_"
    Write-Host ${errorMsg}
    ${errorMsg} | Out-File -FilePath ${logFile} -Append -Encoding UTF8
    exit 1
}
