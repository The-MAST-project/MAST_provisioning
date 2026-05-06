param(
    [string]${AssetsRoot} = ".",
    [string]${InstallRoot} = "C:\Program Files\Sysinternals"
)

${ErrorActionPreference} = "Stop"
${logDir} = Join-Path ${env:ProgramData} "MAST\logs"
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "sysinternals-install.log"

try {
    Write-Host "Starting Sysinternals installation..."

    ${zipPath} = Join-Path ${AssetsRoot} "SysinternalsSuite.zip"
    if (-not (Test-Path ${zipPath})) {
        throw "Sysinternals archive not found at ${zipPath}"
    }

    # Create install directory
    New-Item -ItemType Directory -Path ${InstallRoot} -Force | Out-Null

    Write-Host "Extracting Sysinternals archive to ${InstallRoot}"
    Expand-Archive -Path ${zipPath} -DestinationPath ${InstallRoot} -Force 2>&1 | Tee-Object -FilePath ${logFile}

    # Add Sysinternals to PATH
    ${pathKey} = "HKLM:\System\CurrentControlSet\Control\Session Manager\Environment"
    ${currentPath} = (Get-ItemProperty -Path ${pathKey} -Name "Path").Path

    if (${currentPath} -notlike "*${InstallRoot}*") {
        ${newPath} = "${currentPath};${InstallRoot}"
        Set-ItemProperty -Path ${pathKey} -Name "Path" -Value ${newPath}
        Write-Host "Added Sysinternals to PATH" | Tee-Object -FilePath ${logFile} -Append
    }

    # Verify installation
    if (-not (Test-Path ${InstallRoot})) {
        throw "Sysinternals directory not created after extraction"
    }

    Write-Host "Sysinternals installation completed successfully" | Tee-Object -FilePath ${logFile} -Append
    exit 0
}
catch {
    ${errorMsg} = "Sysinternals installation failed: $_"
    Write-Host ${errorMsg}
    ${errorMsg} | Out-File -FilePath ${logFile} -Append -Encoding UTF8
    exit 1
}
