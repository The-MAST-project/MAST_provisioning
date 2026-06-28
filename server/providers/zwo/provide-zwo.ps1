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
        # NSIS/Inno may spawn children the parent handle alone does not cover;
        # kill the whole tree so a wedged installer cannot hang the run.
        try { & taskkill.exe /T /F /PID $(${p}.Id) 2>$null | Out-Null } catch {}
        try { ${p}.Kill() } catch {}
        throw ("{0} timed out after {1}s (process tree killed)." -f ${Label}, ${TimeoutSec})
    }
    try { ${p}.Refresh() } catch {}
    Write-ZwoLog ("{0} exit code: {1}" -f ${Label}, ${p}.ExitCode)
    if ($null -ne ${p}.ExitCode -and ${p}.ExitCode -ne 0) {
        throw ("{0} failed with exit code {1}." -f ${Label}, ${p}.ExitCode)
    }
}

try {
    Write-ZwoLog "Starting ZWO camera driver and software installation."

    # --- ZWO ASI camera USB driver (ASICAMUSB3) ---
    # The vendor camera-driver setup installs this kernel-mode driver, but under
    # WinRM Session 0 the un-dismissable "trust this publisher?" dialog makes the
    # silent /S install exit 0 without the driver ever binding -- the run reports
    # success but no ASI camera is recognized. Mirror the stage/usbpcap/npcap
    # providers: pre-trust ZWO's catalog publisher cert in
    # LocalMachine\TrustedPublisher, then stage the driver via PnPUtil (the
    # reliable unattended path). This runs unconditionally -- outside the
    # ASIStudio idempotent guard below -- so a re-run that already has ASI Studio
    # still guarantees the camera driver is present. Both steps are idempotent.
    ${zwoCertPath} = Join-Path ${AssetsRoot} "zwo-driver-publisher.cer"
    if (-not (Test-Path ${zwoCertPath})) {
        throw "ZWO driver publisher cert not found at ${zwoCertPath}"
    }
    Write-ZwoLog "Importing ZWO driver publisher cert to LocalMachine\TrustedPublisher..."
    ${zwoCert} = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
    ${zwoCert}.Import(${zwoCertPath})
    ${zwoStore} = New-Object System.Security.Cryptography.X509Certificates.X509Store(
        [System.Security.Cryptography.X509Certificates.StoreName]::TrustedPublisher,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
    )
    ${zwoStore}.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try { ${zwoStore}.Add(${zwoCert}) } finally { ${zwoStore}.Close() }
    Write-ZwoLog ("Trusted ZWO publisher: {0} (thumbprint {1})" -f ${zwoCert}.Subject, ${zwoCert}.Thumbprint)

    # Stage the camera driver in the driver store via PnPUtil. /add-driver only
    # (no /install): no camera is attached during provisioning, so we just want
    # the package in the store -- Windows auto-binds it (no prompt, publisher now
    # trusted) when an ASI camera is later plugged in. The .inf, .sys, .cat and
    # WdfCoInstaller01009.dll are flattened into AssetsRoot by build-mast.ps1.
    ${zwoInfPath} = Join-Path ${AssetsRoot} "ASICAMUSB3.inf"
    if (-not (Test-Path ${zwoInfPath})) {
        throw "ZWO camera driver .inf not found at ${zwoInfPath}"
    }
    Write-ZwoLog ("Staging ZWO camera driver via PnPUtil: {0}" -f ${zwoInfPath})
    ${zwoPnpLog} = Join-Path ${logDir} "zwo-pnputil.log"
    ${zwoPnp} = Start-Process -FilePath 'pnputil.exe' `
        -ArgumentList '/add-driver', "`"${zwoInfPath}`"" `
        -PassThru -WindowStyle Hidden -Wait `
        -RedirectStandardOutput ${zwoPnpLog}
    if (Test-Path ${zwoPnpLog}) {
        Get-Content -LiteralPath ${zwoPnpLog} -ErrorAction SilentlyContinue |
            ForEach-Object { Write-ZwoLog ("  pnputil: {0}" -f $_) }
    }
    Write-ZwoLog ("PnPUtil exited with code: {0}" -f ${zwoPnp}.ExitCode)
    # 0 = success, 259 (ERROR_NO_MORE_ITEMS) = driver already staged.
    if ($null -ne ${zwoPnp}.ExitCode -and ${zwoPnp}.ExitCode -ne 0 -and ${zwoPnp}.ExitCode -ne 259) {
        throw ("PnPUtil failed with exit code {0}" -f ${zwoPnp}.ExitCode)
    }

    # Idempotent re-run guard: ASI Studio is installed LAST, so ASIStudio.exe
    # being present means the whole ZWO suite (camera driver + ASCOM + ASI Studio)
    # already ran. Skip all three installers on a re-run. Re-running the NSIS
    # camera-driver setup over an existing install hangs under WinRM Session 0
    # (no desktop to confirm the driver dialog) -- that is what timed out the 900s
    # guard and failed the run. ASIStudio.exe presence is the success criterion.
    ${asiStudioExe} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
        -Recurse -Filter 'ASIStudio.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName

    if (${asiStudioExe}) {
        Write-ZwoLog ("ZWO suite already installed (ASIStudio.exe at {0}); skipping all installers (idempotent re-run)." -f ${asiStudioExe})
    } else {
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
    }
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
