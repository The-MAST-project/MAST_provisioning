param(
    [string]${AssetsRoot} = ".",
    [string]${InstallRoot} = "C:\Program Files\Stage"
)

${ErrorActionPreference} = "Stop"
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "stage-install.log"

function Write-StageLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-stage.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    ${installerPath} = Join-Path ${AssetsRoot} "xilab-1.20.19-win32_win64.exe"
    if (-not (Test-Path ${installerPath})) {
        throw "Stage installer not found at ${installerPath}"
    }

    # Pre-trust the driver publisher cert so the installer's InfDefaultInstall
    # runs silently without triggering a Windows Security dialog in session 0.
    ${certPath} = Join-Path ${AssetsRoot} "standa-driver-publisher.cer"
    if (-not (Test-Path ${certPath})) {
        throw "Driver publisher cert not found at ${certPath}"
    }
    Write-StageLog "Importing driver publisher cert to TrustedPublisher store..."
    ${cert} = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
    ${cert}.Import(${certPath})
    ${store} = New-Object System.Security.Cryptography.X509Certificates.X509Store(
        [System.Security.Cryptography.X509Certificates.StoreName]::TrustedPublisher,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
    )
    ${store}.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    ${store}.Add(${cert})
    ${store}.Close()
    Write-StageLog ("Cert imported: {0}" -f ${cert}.Subject)

    # /S = NSIS silent; /NCRC skips CRC verification which can stall some NSIS builds.
    # No stdout/stderr redirection: redirecting handles causes the spawned XILab welcome
    # dialog to inherit the pipes, which prevents the installer process from exiting.
    Write-StageLog ("Running Stage installer: {0} /S /NCRC" -f ${installerPath})
    ${p} = Start-Process -FilePath ${installerPath} -ArgumentList '/S', '/NCRC' -PassThru -WindowStyle Hidden
    Write-StageLog ("Installer PID: {0}; polling for xilab.exe..." -f ${p}.Id)

    # Poll for xilab.exe appearing on disk -- that is the signal that the file
    # installation is complete. After files land, the installer may launch a
    # "Quick Start" welcome process and not exit on its own, so kill it once done.
    # Timeout: InfDefaultInstall inside the NSIS installer can block in session 0
    # even with the cert pre-trusted. If files have already landed (typical -- the
    # driver step is last), we kill the stuck installer and let PnPUtil handle the
    # driver separately.
    ${stageExe} = $null
    ${searchPaths} = 'C:\Program Files', 'C:\Program Files (x86)'
    ${pollStart} = [System.Diagnostics.Stopwatch]::StartNew()
    ${pollTimeoutS} = 300
    while ($true) {
        try { ${p}.Refresh() } catch {}
        if (${p}.HasExited -and $null -ne ${p}.ExitCode -and ${p}.ExitCode -ne 0) {
            throw ("XILab installer exited early with code {0}" -f ${p}.ExitCode)
        }
        ${stageExe} = Get-ChildItem -Path ${searchPaths} -Recurse -Filter 'xilab.exe' `
            -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        if (${stageExe}) { break }
        if (${p}.HasExited) {
            throw "XILab installer exited but xilab.exe was not found. Installation may have failed."
        }
        if (${pollStart}.Elapsed.TotalSeconds -ge ${pollTimeoutS}) {
            Write-StageLog "Installer poll timeout -- killing installer and driver-install processes."
            # Kill drvinst.exe / rundll32 that InfDefaultInstall may have spawned.
            Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in 'drvinst', 'rundll32' } |
                ForEach-Object {
                    try { $_.Kill(); Write-StageLog ("Killed driver-install process: {0} (PID {1})" -f $_.Name, $_.Id) } catch {}
                }
            try { ${p}.Kill() } catch {}
            # Check once more after killing -- files are usually on disk by this point.
            ${stageExe} = Get-ChildItem -Path ${searchPaths} -Recurse -Filter 'xilab.exe' `
                -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
            if (-not ${stageExe}) {
                throw "XILab installer timed out and xilab.exe was not found. Installation failed."
            }
            Write-StageLog "Installer was killed after timeout; xilab.exe found -- continuing with PnPUtil."
            break
        }
        Start-Sleep -Seconds 5
    }
    try { ${p}.Kill() } catch {}
    # Kill any child/welcome processes the NSIS installer may have spawned before exiting.
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like '*XILab*' -or $_.Name -like 'xilab*' } |
        ForEach-Object {
            try { $_.Kill(); Write-StageLog ("Killed lingering XILab process: {0} (PID {1})" -f $_.Name, $_.Id) } catch {}
        }
    Write-StageLog ("XILab files installed: {0}" -f ${stageExe})

    # Explicitly add the driver to the Windows driver store using PnPUtil.
    # This is the reliable, unattended alternative to the installer's InfDefaultInstall
    # call, which can block on a signing dialog if the cert is not yet trusted.
    ${infPath} = Join-Path (Split-Path -Parent ${stageExe}) "driver\Standa_8SMC4-5.inf"
    if (-not (Test-Path ${infPath})) {
        throw "Driver .inf not found at expected path: ${infPath}"
    }
    Write-StageLog ("Installing driver via PnPUtil: {0}" -f ${infPath})
    # /add-driver stages the driver in the Windows driver store only; omit /install to avoid
    # triggering Plug and Play device attachment (DrvInst.exe) which can block on a UI dialog
    # if a matching device is present. The driver will be applied automatically when the
    # hardware is first connected.
    ${pnpLog} = Join-Path ${logDir} "pnputil.log"
    ${pnp} = Start-Process -FilePath 'pnputil.exe' `
        -ArgumentList '/add-driver', "`"${infPath}`"" `
        -PassThru -WindowStyle Hidden -Wait `
        -RedirectStandardOutput ${pnpLog}
    if (Test-Path ${pnpLog}) {
        Get-Content -LiteralPath ${pnpLog} -ErrorAction SilentlyContinue |
            ForEach-Object { Write-StageLog ("  pnputil: {0}" -f $_) }
    }
    Write-StageLog ("PnPUtil exited with code: {0}" -f ${pnp}.ExitCode)
    # 0 = success, 259 (ERROR_NO_MORE_ITEMS) = driver already staged.
    if ($null -ne ${pnp}.ExitCode -and ${pnp}.ExitCode -ne 0 -and ${pnp}.ExitCode -ne 259) {
        throw ("PnPUtil failed with exit code {0}" -f ${pnp}.ExitCode)
    }

    Write-StageLog ("Stage installation completed successfully: {0}" -f ${stageExe})
    exit 0
}
catch {
    ${errorMsg} = ("Stage installation failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
