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

    # NSIS installs to its own default path; search rather than assume InstallRoot.
    Start-Sleep -Seconds 3
    ${phd2Exe} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
        -Recurse -Filter 'phd2.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not ${phd2Exe}) {
        throw "phd2.exe not found after installation"
    }
    Write-Host "Found phd2.exe at: ${phd2Exe}"

    Write-Host "PHD2 installation completed successfully" | Tee-Object -FilePath ${logFile} -Append
    exit 0
}
catch {
    ${errorMsg} = "PHD2 installation failed: $_"
    Write-Host ${errorMsg}
    ${errorMsg} | Out-File -FilePath ${logFile} -Append -Encoding UTF8
    exit 1
}
