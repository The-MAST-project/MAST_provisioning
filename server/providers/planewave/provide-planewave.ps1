param(
    [string]${AssetsRoot} = "."
)

${ErrorActionPreference} = "Stop"
${logDir} = Join-Path ${env:ProgramData} "MAST\logs"
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "planewave-install.log"

try {
    Write-Host "Starting PlaneWave installation..."

    # Install PWI4
    ${pwi4InstallerPath} = Join-Path ${AssetsRoot} "assets\PWI4_Setup.exe"
    if (-not (Test-Path ${pwi4InstallerPath})) {
        throw "PWI4 installer not found at ${pwi4InstallerPath}"
    }

    Write-Host "Installing PWI4 telescope control software..." | Tee-Object -FilePath ${logFile}
    & ${pwi4InstallerPath} /S 2>&1 | Tee-Object -FilePath ${logFile} -Append

    if (${LASTEXITCODE} -ne 0) {
        throw "PWI4 installer exited with code ${LASTEXITCODE}"
    }

    # Extract PS3 CLI tools
    ${ps3cliZipPath} = Join-Path ${AssetsRoot} "assets\ps3cli.zip"
    if (-not (Test-Path ${ps3cliZipPath})) {
        throw "PS3 CLI archive not found at ${ps3cliZipPath}"
    }

    ${ps3cliDestPath} = "C:\Users\mast\Documents\PlaneWave\ps3cli"
    New-Item -ItemType Directory -Path ${ps3cliDestPath} -Force | Out-Null

    Write-Host "Extracting PS3 CLI tools to ${ps3cliDestPath}" | Tee-Object -FilePath ${logFile} -Append
    Expand-Archive -Path ${ps3cliZipPath} -DestinationPath ${ps3cliDestPath} -Force 2>&1 | Tee-Object -FilePath ${logFile} -Append

    # Verify PWI4 installation
    ${pwi4ExePath} = "C:\Program Files\PlaneWave Instruments\PWI4\pwi4.exe"
    if (-not (Test-Path ${pwi4ExePath})) {
        throw "PWI4 executable not found after installation at ${pwi4ExePath}"
    }

    # Verify PS3 CLI extraction
    if (-not (Test-Path ${ps3cliDestPath})) {
        throw "PS3 CLI directory not created after extraction at ${ps3cliDestPath}"
    }

    Write-Host "PlaneWave installation completed successfully" | Tee-Object -FilePath ${logFile} -Append
    exit 0
}
catch {
    ${errorMsg} = "PlaneWave installation failed: $_"
    Write-Host ${errorMsg}
    ${errorMsg} | Out-File -FilePath ${logFile} -Append -Encoding UTF8
    exit 1
}
