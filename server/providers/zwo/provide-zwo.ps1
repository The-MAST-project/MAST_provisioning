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

function Write-ZwoLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

# Write-Host does not pipe to Tee-Object in Windows PowerShell 5.1; always seed the log file.
Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] ZWO provide-zwo.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

function Invoke-ZwoInstaller {
    param(
        [string]${Path},
        [string[]]${ArgumentList},
        [int]${TimeoutSec} = 900,
        [string]${Label}
    )
    Write-ZwoLog ("{0}: {1}" -f ${Label}, ${Path})
    Write-ZwoLog ("  args: {0}" -f (${ArgumentList} -join ' '))
    ${p} = Start-Process -FilePath ${Path} -ArgumentList ${ArgumentList} -PassThru -NoNewWindow
    if (-not ${p}) {
        throw ("Start-Process did not return a process object for {0}" -f ${Path})
    }
    ${finished} = ${p}.WaitForExit(${TimeoutSec} * 1000)
    if (-not ${finished}) {
        try { ${p}.Kill() } catch {}
        throw ("{0} timed out after {1}s (process killed)." -f ${Label}, ${TimeoutSec})
    }
    try { ${p}.Refresh() } catch {}
    Write-ZwoLog ("{0} exit code: {1}" -f ${Label}, ${p}.ExitCode)
    if ($null -ne ${p}.ExitCode -and ${p}.ExitCode -ne 0) {
        throw ("{0} failed with exit code {1}." -f ${Label}, ${p}.ExitCode)
    }
}

try {
    Write-ZwoLog "Starting ZWO camera driver and software installation."

    # ZWO ASI camera driver: NSIS (vendor) -- /S silent.
    ${asiDriverPath} = Join-Path ${AssetsRoot} "ZWO_ASI_Cameras_driver_Setup_V3.25.exe"
    if (-not (Test-Path ${asiDriverPath})) {
        throw "ZWO ASI camera driver not found at ${asiDriverPath}"
    }
    Invoke-ZwoInstaller -Path ${asiDriverPath} -ArgumentList @('/S') -Label 'ZWO ASI camera driver'

    # ZWO ASCOM: Inno Setup -- do not use NSIS /S (hangs or fails under WinRM session 0).
    ${ascomPath} = Join-Path ${AssetsRoot} "ZWO_ASCOM_Setup_V6.5.32.exe"
    if (-not (Test-Path ${ascomPath})) {
        throw "ZWO ASCOM driver not found at ${ascomPath}"
    }
    ${ascomInnoLog} = Join-Path ${logDir} "zwo-ascom-inno-setup.log"
    Invoke-ZwoInstaller -Path ${ascomPath} -ArgumentList @(
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/SP-',
        ('/LOG={0}' -f ${ascomInnoLog})
    ) -Label 'ZWO ASCOM (Inno)'

    # ASI Studio: NSIS -- /S silent.
    ${asiStudioPath} = Join-Path ${AssetsRoot} "ASIStudio_V1.16.2_x64_Setup.exe"
    if (-not (Test-Path ${asiStudioPath})) {
        throw "ASI Studio installer not found at ${asiStudioPath}"
    }
    Invoke-ZwoInstaller -Path ${asiStudioPath} -ArgumentList @('/S') -Label 'ASI Studio'
    Start-Sleep -Seconds 5

    ${asiStudioExe} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
        -Recurse -Filter 'ASIStudio.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not ${asiStudioExe}) {
        throw "ASIStudio.exe not found after installation"
    }
    Write-ZwoLog ("Found ASIStudio.exe at: {0}" -f ${asiStudioExe})

    Write-ZwoLog "ZWO installation completed successfully"
    exit 0
}
catch {
    ${errorMsg} = "ZWO installation failed: $_"
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
