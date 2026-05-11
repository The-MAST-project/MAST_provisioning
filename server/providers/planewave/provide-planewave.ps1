param(
    [string]${AssetsRoot} = "."
)

${ErrorActionPreference} = "Stop"
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "planewave-install.log"

try {
    Write-Host "Starting PlaneWave installation..."

    # Install PWI4
    ${pwi4InstallerPath} = Join-Path ${AssetsRoot} "Setup_PWI_4.1.8_Final.exe"
    if (-not (Test-Path ${pwi4InstallerPath})) {
        throw "PWI4 installer not found at ${pwi4InstallerPath}"
    }

    Write-Host "Installing PWI4 telescope control software..." | Tee-Object -FilePath ${logFile}
    & ${pwi4InstallerPath} /S 2>&1 | Tee-Object -FilePath ${logFile} -Append
    Start-Sleep -Seconds 5

    # Locate pwi4.exe - NSIS installs to its own default path; search rather than hardcode.
    ${pwi4ExePath} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
        -Recurse -Filter 'pwi4.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not ${pwi4ExePath}) {
        throw "pwi4.exe not found after installation"
    }
    Write-Host "Found pwi4.exe at: ${pwi4ExePath}"

    # Extract PS3 CLI tools
    ${ps3cliZipPath} = Join-Path ${AssetsRoot} "ps3cli.zip"
    if (-not (Test-Path ${ps3cliZipPath})) {
        throw "PS3 CLI archive not found at ${ps3cliZipPath}"
    }

    ${ps3cliDestPath} = "C:\Users\mast\Documents\PlaneWave\ps3cli"
    New-Item -ItemType Directory -Path ${ps3cliDestPath} -Force | Out-Null

    Write-Host "Extracting PS3 CLI tools to ${ps3cliDestPath}" | Tee-Object -FilePath ${logFile} -Append
    Expand-Archive -Path ${ps3cliZipPath} -DestinationPath ${ps3cliDestPath} -Force 2>&1 | Tee-Object -FilePath ${logFile} -Append

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
