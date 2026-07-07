#requires -RunAsAdministrator
param(
    [string]${AssetsRoot} = "."
)

${ErrorActionPreference} = "Stop"
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "vcredist2013-install.log"

function Write-VcrLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

function Test-VcRuntimeInstalled {
    param([string]${Arch})
    # VC++ 2013 (12.0) registry presence check.
    ${key64} = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\12.0\VC\Runtimes\x64'
    ${key86} = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\12.0\VC\Runtimes\x86'
    if (${Arch} -eq 'x64') { return (Test-Path -LiteralPath ${key64}) }
    return (Test-Path -LiteralPath ${key86})
}

function Invoke-VcrInstaller {
    param(
        [string]${Path},
        [string]${Arch}
    )
    Write-VcrLog ("Installing VC++ 2013 {0}: {1}" -f ${Arch}, ${Path})
    ${p} = Start-Process -FilePath ${Path} -ArgumentList @('/quiet', '/norestart') -PassThru -NoNewWindow
    if (-not ${p}) { throw ("Start-Process returned no object for {0}" -f ${Path}) }
    ${finished} = ${p}.WaitForExit(300000)
    if (-not ${finished}) {
        try { ${p}.Kill() } catch {}
        throw ("VC++ 2013 {0} installer timed out after 300s." -f ${Arch})
    }
    try { ${p}.Refresh() } catch {}
    Write-VcrLog ("VC++ 2013 {0} installer exit code: {1}" -f ${Arch}, ${p}.ExitCode)
    # Exit code 3010 = success, reboot required (acceptable).
    if ($null -ne ${p}.ExitCode -and ${p}.ExitCode -ne 0 -and ${p}.ExitCode -ne 3010) {
        throw ("VC++ 2013 {0} installer failed with exit code {1}." -f ${Arch}, ${p}.ExitCode)
    }
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-vcredist2013.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    foreach (${arch} in @('x64', 'x86')) {
        ${installerName} = ("vcredist_{0}_2013.exe" -f ${arch})
        ${installerPath} = Join-Path ${AssetsRoot} ${installerName}
        if (-not (Test-Path -LiteralPath ${installerPath})) {
            throw ("VC++ 2013 {0} installer not found at {1}" -f ${arch}, ${installerPath})
        }
        if (Test-VcRuntimeInstalled -Arch ${arch}) {
            Write-VcrLog ("VC++ 2013 {0} already installed -- skipping." -f ${arch})
        } else {
            Invoke-VcrInstaller -Path ${installerPath} -Arch ${arch}
        }
    }
    Write-VcrLog "VC++ 2013 redistributables installation completed."
    exit 0
}
catch {
    ${msg} = ("vcredist2013 installation failed: {0}" -f $_)
    Write-Host ${msg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${msg}
    exit 1
}
