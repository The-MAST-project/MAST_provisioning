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

    ${installerPath} = Join-Path ${AssetsRoot} "VSCodeUserSetup-x64-1.105.1.exe"
    if (-not (Test-Path ${installerPath})) {
        throw "VSCode installer not found at ${installerPath}"
    }

    # VSCode UserSetup is NSIS-based; /S = silent, /D= must be last with no spaces.
    # Use /SUPPRESSMSGBOXES to avoid any remaining dialogs.
    Write-Host "Running VSCode installer: ${installerPath} /S /SUPPRESSMSGBOXES"
    & ${installerPath} /S /SUPPRESSMSGBOXES 2>&1 | Tee-Object -FilePath ${logFile}

    Start-Sleep -Seconds 5

    # UserSetup installs per-user by default; find Code.exe wherever it landed.
    ${vscodeExe} = Get-ChildItem -Path 'C:\Program Files', "$env:LOCALAPPDATA\Programs" `
        -Recurse -Filter 'Code.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not ${vscodeExe}) {
        throw "Code.exe not found after installation"
    }
    Write-Host "Found Code.exe at: ${vscodeExe}"

    Write-Host "VSCode installation completed successfully" | Tee-Object -FilePath ${logFile} -Append
    exit 0
}
catch {
    ${errorMsg} = "VSCode installation failed: $_"
    Write-Host ${errorMsg}
    ${errorMsg} | Out-File -FilePath ${logFile} -Append -Encoding UTF8
    exit 1
}
