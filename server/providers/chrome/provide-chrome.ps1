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

try {
    Write-Host "Starting Chrome installation..."

    ${installerPath} = Join-Path ${AssetsRoot} "ChromeSetup.exe"
    if (-not (Test-Path ${installerPath})) {
        throw "Chrome installer not found at ${installerPath}"
    }

    Write-Host "Running Chrome installer: ${installerPath}"
    # Avoid piping native stderr through PowerShell with ErrorAction Stop; Chrome's stub logs
    # VERBOSE lines to stderr which become ErrorRecord and terminate before we can check chrome.exe.
    ${stderrLog} = Join-Path ${logDir} "chrome-install-stderr.log"
    ${p} = Start-Process -FilePath ${installerPath} -ArgumentList @('/silent', '/install') -PassThru -Wait -WindowStyle Hidden `
        -RedirectStandardOutput ${logFile} -RedirectStandardError ${stderrLog}
    try { ${p}.Refresh() } catch {}
    ${installerExit} = ${p}.ExitCode
    if (Test-Path -LiteralPath ${stderrLog}) {
        Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value '--- native stderr ---'
        Get-Content -LiteralPath ${stderrLog} -ErrorAction SilentlyContinue | Add-Content -LiteralPath ${logFile} -Encoding UTF8
    }

    # The online stub may exit non-zero even when Chrome installs successfully.
    # Treat presence of chrome.exe as the authoritative success criterion.
    ${chromeExe} = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    if (-not (Test-Path ${chromeExe})) {
        throw "Chrome executable not found after installation (installer exit: ${installerExit})"
    }

    Write-Host "Chrome installation completed successfully" | Tee-Object -FilePath ${logFile} -Append
    exit 0
}
catch {
    ${errorMsg} = "Chrome installation failed: $_"
    Write-Host ${errorMsg}
    ${errorMsg} | Out-File -FilePath ${logFile} -Append -Encoding UTF8
    exit 1
}
