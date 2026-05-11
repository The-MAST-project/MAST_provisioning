param(
    [string]${AssetsRoot} = "."
)

${ErrorActionPreference} = "Stop"
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "zwo-install.log"

function Invoke-Installer {
    param([string]$Path, [string]$Args = '/S', [int]$TimeoutSec = 120)
    Write-Host "Running: $Path $Args"
    $p = Start-Process -FilePath $Path -ArgumentList $Args -PassThru -NoNewWindow
    $finished = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $finished) {
        $p.Kill()
        Write-Warning "Installer timed out after ${TimeoutSec}s - killed"
    }
    return $p.ExitCode
}

try {
    Write-Host "Starting ZWO camera driver installation..."

    ${asiDriverPath} = Join-Path ${AssetsRoot} "ZWO_ASI_Cameras_driver_Setup_V3.25.exe"
    if (-not (Test-Path ${asiDriverPath})) {
        throw "ZWO ASI camera driver not found at ${asiDriverPath}"
    }
    Write-Host "Installing ZWO ASI Camera Drivers..." | Tee-Object -FilePath ${logFile}
    Invoke-Installer -Path ${asiDriverPath} | Out-Null

    ${ascomPath} = Join-Path ${AssetsRoot} "ZWO_ASCOM_Setup_V6.5.32.exe"
    if (-not (Test-Path ${ascomPath})) {
        throw "ZWO ASCOM driver not found at ${ascomPath}"
    }
    Write-Host "Installing ZWO ASCOM Drivers..." | Tee-Object -FilePath ${logFile} -Append
    Invoke-Installer -Path ${ascomPath} | Out-Null

    ${asiStudioPath} = Join-Path ${AssetsRoot} "ASIStudio_V1.16.2_x64_Setup.exe"
    if (-not (Test-Path ${asiStudioPath})) {
        throw "ASI Studio installer not found at ${asiStudioPath}"
    }
    Write-Host "Installing ASI Studio..." | Tee-Object -FilePath ${logFile} -Append
    Invoke-Installer -Path ${asiStudioPath} | Out-Null
    Start-Sleep -Seconds 5

    ${asiStudioExe} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
        -Recurse -Filter 'ASIStudio.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not ${asiStudioExe}) {
        throw "ASIStudio.exe not found after installation"
    }
    Write-Host "Found ASIStudio.exe at: ${asiStudioExe}"

    Write-Host "ZWO installation completed successfully" | Tee-Object -FilePath ${logFile} -Append
    exit 0
}
catch {
    ${errorMsg} = "ZWO installation failed: $_"
    Write-Host ${errorMsg}
    ${errorMsg} | Out-File -FilePath ${logFile} -Append -Encoding UTF8
    exit 1
}
