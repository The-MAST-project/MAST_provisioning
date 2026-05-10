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

    ${installerPath} = Join-Path ${AssetsRoot} "xilab-1.20.19-win32_win64.exe"
    if (-not (Test-Path ${installerPath})) {
        throw "Stage installer not found at ${installerPath}"
    }

    # /S = NSIS silent. Use Start-Process so we can enforce a timeout; piping
    # to Tee-Object blocks indefinitely if the installer shows a dialog.
    Write-Host "Running Stage installer: ${installerPath} /S"
    $p = Start-Process -FilePath ${installerPath} -ArgumentList '/S' -PassThru -NoNewWindow
    $finished = $p.WaitForExit(180000)
    if (-not $finished) { $p.Kill(); Write-Warning "XILab installer timed out after 180s - killed" }

    # NSIS silent installers sometimes exit before all files are written; give it a moment.
    Start-Sleep -Seconds 5

    # Locate xilab.exe - search Program Files only (not all of C:\).
    ${stageExe} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
        -Recurse -Filter 'xilab.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not ${stageExe}) {
        throw "xilab.exe not found after installation - installer may have failed silently"
    }
    Write-Host "Found xilab.exe at: ${stageExe}"

    Write-Host "Stage installation completed successfully: ${stageExe}" | Tee-Object -FilePath ${logFile} -Append
    exit 0
}
catch {
    ${errorMsg} = "Stage installation failed: $_"
    Write-Host ${errorMsg}
    ${errorMsg} | Out-File -FilePath ${logFile} -Append -Encoding UTF8
    exit 1
}
