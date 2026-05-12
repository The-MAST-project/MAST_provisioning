param(
    [string]${AssetsRoot} = ".",
    [string]${InstallRoot} = "C:\Program Files\Sysinternals"
)

${ErrorActionPreference} = "Stop"
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "sysinternals-install.log"

function Write-SysLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-sysinternals.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    ${zipPath} = Join-Path ${AssetsRoot} "SysinternalsSuite.zip"
    if (-not (Test-Path ${zipPath})) {
        throw "Sysinternals archive not found at ${zipPath}"
    }

    New-Item -ItemType Directory -Path ${InstallRoot} -Force | Out-Null
    Write-SysLog ("Extracting Sysinternals archive to {0}" -f ${InstallRoot})
    Expand-Archive -Path ${zipPath} -DestinationPath ${InstallRoot} -Force
    Write-SysLog "Extraction complete."

    ${pathKey} = "HKLM:\System\CurrentControlSet\Control\Session Manager\Environment"
    ${currentPath} = (Get-ItemProperty -Path ${pathKey} -Name "Path").Path
    if (${currentPath} -notlike ("*{0}*" -f ${InstallRoot})) {
        Set-ItemProperty -Path ${pathKey} -Name "Path" -Value ("${currentPath};${InstallRoot}")
        Write-SysLog ("Added to PATH: {0}" -f ${InstallRoot})
    } else {
        Write-SysLog "PATH already contains Sysinternals directory."
    }

    if (-not (Test-Path ${InstallRoot})) {
        throw "Sysinternals directory not created after extraction"
    }

    Write-SysLog "Sysinternals installation completed successfully."
    exit 0
}
catch {
    ${errorMsg} = ("Sysinternals installation failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
