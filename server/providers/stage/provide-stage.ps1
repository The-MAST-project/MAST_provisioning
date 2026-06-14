param(
    [string]${AssetsRoot}  = ".",
    [string]${InstallRoot} = "C:\Program Files\Stage",
    # Reinstall even if XILab is already present (otherwise it is left as-is; the
    # NSIS installer + its ~240s wait and the driver staging are skipped).
    [switch]${Force}
)

${ErrorActionPreference} = "Stop"
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir}     = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile}    = Join-Path ${logDir} "stage-install.log"

# Do NOT also write to provisioning-execute.log directly. The orchestrator
# (execute-mast-provisioning.ps1) holds that file open via Tee-Object for
# the duration of every provider invocation; an unrelated Add-Content from
# in here races into ERROR_SHARING_VIOLATION, which then bubbles up
# (Stop-mode), the catch block tries to write its own error to the SAME
# file, that throws again, and the orchestrator deadlocks reading a pipe
# that never closed. Trust the orchestrator's stream capture -- our
# Write-Host below is already mirrored to provisioning-execute.log by
# the parent. (Discovered 2026-05-25; see DECISIONS.md.)
function Write-StageLog {
    param([AllowEmptyString()][string]${Line})
    ${ts}  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    ${msg} = ("[{0}] [stage] {1}" -f ${ts}, ${Line})
    try { Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${msg} -ErrorAction Stop }
    catch { Write-Host ("[stage] [WARN] stage-install.log write failed: {0}" -f $_.Exception.Message) }
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value `
    ("[{0}] provide-stage.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# Idempotent skip: XILab.exe present (the same paths checked below + by verify)
# means Stage is installed. Skip the NSIS installer + driver staging (pnputil is
# idempotent anyway). Use -Force to reinstall.
if (-not ${Force} -and ((Test-Path 'C:\Program Files\XILab\XILab.exe') -or (Test-Path 'C:\Program Files (x86)\XILab\XILab.exe'))) {
    Write-StageLog "XILab already installed; skipping installer + driver staging. Use -Force to reinstall."
    exit 0
}

try {
    ${installerPath} = Join-Path ${AssetsRoot} "xilab-1.20.12-win32_win64.exe"
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
    ${cert}  = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
    ${cert}.Import(${certPath})
    ${store} = New-Object System.Security.Cryptography.X509Certificates.X509Store(
        [System.Security.Cryptography.X509Certificates.StoreName]::TrustedPublisher,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
    )
    ${store}.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    ${store}.Add(${cert})
    ${store}.Close()
    Write-StageLog ("Cert imported: {0}" -f ${cert}.Subject)

    # Run the NSIS installer silently.
    # /S = silent; /NCRC skips CRC check which can stall some NSIS builds.
    # Redirect stdout/stderr to private files so this script's outer stdout pipe
    # (created by mast-invoke-child.ps1) is not inherited by the installer or its
    # children. Without this, a child process holding the pipe open would cause
    # mast-invoke-child.ps1's WaitForExit() to block after we exit.
    ${installerOut} = Join-Path ${logDir} "xilab-installer-stdout.log"
    ${installerErr} = Join-Path ${logDir} "xilab-installer-stderr.log"
    Write-StageLog ("Running Stage installer: {0} /S /NCRC" -f ${installerPath})
    ${p} = Start-Process -FilePath ${installerPath} -ArgumentList '/S', '/NCRC' `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput ${installerOut} `
        -RedirectStandardError  ${installerErr}
    ${installerPid} = ${p}.Id
    Write-StageLog ("Installer PID: {0}" -f ${installerPid})

    # The NSIS installer extracts all files first, then runs post-install steps
    # as child processes (observed: InfDefaultInstall.exe for driver staging).
    # InfDefaultInstall can block in session 0 when the driver is unsigned or
    # triggers a signing prompt. We handle the driver ourselves via PnPUtil below,
    # so once the files are on disk we terminate any children the installer is
    # waiting on and let it exit cleanly. Fall back to a full tree kill only if
    # the installer is still running after the deadline.
    ${deadlineS}   = 240
    ${deadline}    = (Get-Date).AddSeconds(${deadlineS})
    ${exitedClean} = $false
    ${childKilled} = $false
    Write-StageLog ("Waiting up to {0}s for installer to finish..." -f ${deadlineS})
    while ((Get-Date) -lt ${deadline}) {
        if (${p}.HasExited) {
            ${exitedClean} = $true
            break
        }
        if (-not ${childKilled} -and (Test-Path -LiteralPath 'C:\Program Files\XILab\XILab.exe')) {
            ${children} = @(Get-CimInstance Win32_Process `
                -Filter "ParentProcessId = ${installerPid}" `
                -ErrorAction SilentlyContinue)
            if (${children}.Count -gt 0) {
                foreach (${c} in ${children}) {
                    Write-StageLog ("Terminating Quick Start child: {0} (PID {1})" -f ${c}.Name, ${c}.ProcessId)
                    Stop-Process -Id ${c}.ProcessId -Force -ErrorAction SilentlyContinue
                }
                ${childKilled} = $true
                Start-Sleep -Seconds 5
            }
        }
        Start-Sleep -Seconds 3
    }

    if (${exitedClean}) {
        Write-StageLog ("Installer exited cleanly with code: {0}" -f ${p}.ExitCode)
        if ($null -ne ${p}.ExitCode -and ${p}.ExitCode -ne 0) {
            throw ("XILab installer exited with non-zero code: {0}" -f ${p}.ExitCode)
        }
    } else {
        Write-StageLog ("Installer still running after {0}s -- terminating." -f ${deadlineS})
        & taskkill /F /T /PID ${installerPid} 2>&1 | ForEach-Object { Write-StageLog ("  taskkill: {0}" -f $_) }
    }

    # Locate xilab.exe. Check the two standard paths first (fast); fall back to a
    # limited-depth recursive search so we handle non-standard install locations without
    # scanning the entire Program Files tree recursively (which can block or be very slow
    # while the installer is still writing files).
    Write-StageLog "Locating xilab.exe..."
    ${knownPaths} = @(
        'C:\Program Files\XILab\XILab.exe',
        'C:\Program Files (x86)\XILab\XILab.exe'
    )
    ${stageExe} = ${knownPaths} | Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if (-not ${stageExe}) {
        Write-StageLog "Not found at standard paths; scanning Program Files (depth 3)..."
        ${stageExe} = Get-ChildItem `
            -Path 'C:\Program Files', 'C:\Program Files (x86)' `
            -Depth 3 -Filter 'xilab.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not ${stageExe}) {
        throw "xilab.exe not found after installer completed. Installation failed."
    }
    Write-StageLog ("XILab files installed: {0}" -f ${stageExe})

    # Explicitly stage the driver via PnPUtil -- the reliable unattended alternative to
    # the installer's InfDefaultInstall, which can block in session 0 on a signing dialog.
    # /add-driver stages it in the driver store only; no device attachment triggered.
    ${infPath} = Join-Path (Split-Path -Parent ${stageExe}) "driver\Standa_8SMC4-5.inf"
    if (-not (Test-Path ${infPath})) {
        throw "Driver .inf not found at expected path: ${infPath}"
    }
    Write-StageLog ("Installing driver via PnPUtil: {0}" -f ${infPath})
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
    # Write-Host first so the orchestrator's stream capture gets it; then try
    # the file write. NEVER call Add-Content on provisioning-execute.log from
    # in here (see Write-StageLog comment). Defensive try/catch so a file-lock
    # failure on stage-install.log can't re-throw and orphan installer children.
    Write-Host ${errorMsg}
    try { Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg} -ErrorAction Stop }
    catch { Write-Host ("[stage] [WARN] could not write error to stage-install.log: {0}" -f $_.Exception.Message) }

    # Best-effort: if the installer or any descendant is still alive at this
    # point, kill the whole tree. Previously a thrown exception in Write-StageLog
    # left xilab.exe orphaned for 30+ min before manual intervention.
    if (${installerPid}) {
        try {
            Write-Host ("[stage] catch-cleanup taskkill /F /T /PID {0}" -f ${installerPid})
            & taskkill /F /T /PID ${installerPid} 2>&1 | Out-Null
        } catch {}
    }
    exit 1
}
