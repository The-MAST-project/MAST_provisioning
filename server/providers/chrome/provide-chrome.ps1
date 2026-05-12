param(
    [string]${AssetsRoot} = "."
)

${ErrorActionPreference} = "Stop"
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "chrome-install.log"

function Write-ChromeLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-chrome.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    ${installerPath} = Join-Path ${AssetsRoot} "ChromeSetup.exe"
    if (-not (Test-Path ${installerPath})) {
        throw "Chrome installer not found at ${installerPath}"
    }

    Write-ChromeLog ("Running Chrome installer: {0} /silent /install" -f ${installerPath})
    # Avoid piping native stderr through PowerShell; Chrome's stub emits VERBOSE lines to
    # stderr which become ErrorRecord and can terminate before we check chrome.exe.
    ${stderrLog} = Join-Path ${logDir} "chrome-install-stderr.log"
    ${stdoutLog} = Join-Path ${logDir} "chrome-install-stdout.log"
    ${p} = Start-Process -FilePath ${installerPath} -ArgumentList @('/silent', '/install') -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput ${stdoutLog} -RedirectStandardError ${stderrLog}
    Write-ChromeLog ("Installer PID: {0}; waiting up to 300s..." -f ${p}.Id)
    ${finished} = ${p}.WaitForExit(300000)
    try { ${p}.Refresh() } catch {}
    if (-not ${finished}) {
        try { ${p}.Kill() } catch {}
        throw "Chrome installer timed out after 300s (process killed)."
    }
    Write-ChromeLog ("Chrome installer exited. ExitCode={0}" -f ${p}.ExitCode)
    if (Test-Path -LiteralPath ${stdoutLog}) {
        Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value '--- installer stdout ---'
        Get-Content -LiteralPath ${stdoutLog} -ErrorAction SilentlyContinue | Add-Content -LiteralPath ${logFile} -Encoding UTF8
    }
    if (Test-Path -LiteralPath ${stderrLog}) {
        Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value '--- installer stderr ---'
        Get-Content -LiteralPath ${stderrLog} -ErrorAction SilentlyContinue | Add-Content -LiteralPath ${logFile} -Encoding UTF8
    }

    # The online stub may exit non-zero even when Chrome installs successfully.
    # Treat presence of chrome.exe as the authoritative success criterion.
    ${chromeExe} = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    if (-not (Test-Path ${chromeExe})) {
        throw ("Chrome executable not found after installation (installer exit: {0})" -f ${p}.ExitCode)
    }

    Write-ChromeLog "Chrome installation completed successfully."
    exit 0
}
catch {
    ${errorMsg} = ("Chrome installation failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
