param(
    [string]${AssetsRoot} = ".",
    [string]${InstallerName} = "GoogleChromeStandaloneEnterprise64.msi"
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
    ${installerPath} = Join-Path ${AssetsRoot} ${InstallerName}
    if (-not (Test-Path ${installerPath})) {
        throw "Chrome Enterprise MSI not found at ${installerPath}"
    }
    # msiexec does NOT resolve a relative path (".\foo.msi") against the caller's
    # working directory -- it fails with 1619 (ERROR_INSTALL_PACKAGE_OPEN_FAILED).
    # Resolve to a full path before handing it to msiexec.
    ${installerPath} = (Resolve-Path -LiteralPath ${installerPath}).Path

    # Offline Chrome Enterprise standalone MSI: installs entirely from the staged
    # file with NO network access at install time. This deliberately replaces the
    # old online ChromeSetup.exe stub, which downloads Chrome via WinHTTP/BITS and
    # fails behind bcproxy -- the stub ignores the WinINet revocation knob, and
    # the unit's CryptoAPI (cryptnet) revocation retrieval cannot complete through
    # the proxy (0x80070057). The offline MSI sidesteps that entirely and matches
    # how every other fleet app is installed (staged installer, not a net-fetching
    # stub). See DECISIONS.md 2026-05-27.
    ${msiLog} = Join-Path ${logDir} "chrome-msiexec.log"
    ${msiArgs} = @('/i', ${installerPath}, '/qn', '/norestart', '/L*v', ${msiLog})
    Write-ChromeLog ("Installing Chrome Enterprise MSI: msiexec.exe {0}" -f (${msiArgs} -join ' '))
    ${p} = Start-Process -FilePath 'msiexec.exe' -ArgumentList ${msiArgs} -PassThru -Wait -WindowStyle Hidden
    try { ${p}.Refresh() } catch {}
    ${exit} = ${p}.ExitCode
    Write-ChromeLog ("msiexec exited. ExitCode={0}" -f ${exit})
    # 0 = success; 3010 = success, reboot required. A $null ExitCode is treated as
    # inconclusive and falls through to the chrome.exe presence check below.
    if ($null -ne ${exit} -and ${exit} -ne 0 -and ${exit} -ne 3010) {
        throw ("msiexec failed installing Chrome (exit {0}). See {1}" -f ${exit}, ${msiLog})
    }

    # Presence of chrome.exe is the authoritative success criterion.
    ${chromeExe} = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    if (-not (Test-Path ${chromeExe})) {
        throw ("Chrome executable not found after installation (msiexec exit: {0})" -f ${exit})
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
