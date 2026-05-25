param(
    [string]${AssetsRoot} = ".",
    [string]${InstallerPattern} = "npcap-*.exe"
)

${ErrorActionPreference} = "Stop"

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "npcap-install.log"

function Write-NpcapLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-npcap.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    # Resolve assets dir: prefer .\assets next to this script, fall back to AssetsRoot
    ${assetsDir} = Join-Path ${PSScriptRoot} 'assets'
    if (-not (Test-Path -LiteralPath ${assetsDir})) { ${assetsDir} = ${AssetsRoot} }

    # Idempotency: skip if Npcap service already exists.
    ${existing} = Get-Service -Name 'npcap' -ErrorAction SilentlyContinue
    if ($null -ne ${existing}) {
        Write-NpcapLog ("Npcap service already present (Status={0}); skipping install." -f ${existing}.Status)
    } else {
        ${candidates} = @(Get-ChildItem -Path ${assetsDir} -Filter ${InstallerPattern} -File -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending)
        if (${candidates}.Count -eq 0) {
            throw ("No Npcap installer matched '{0}' under {1}" -f ${InstallerPattern}, ${assetsDir})
        }
        ${installerPath} = ${candidates}[0].FullName
        Write-NpcapLog ("Running Npcap installer: {0}" -f ${installerPath})

        # NSIS-style silent install with feature flags chosen to match mastw:
        #   /S                    - silent
        #   /loopback_support=yes - install Npcap Loopback Adapter (capture from localhost)
        #   /winpcap_mode=yes     - WinPcap-compatible API for legacy callers
        #   /admin_only=no        - allow non-admin processes to capture
        #   /dlt_null=yes         - DLT_NULL on the loopback adapter (matches mastw)
        ${npcapArgs} = @('/S', '/loopback_support=yes', '/winpcap_mode=yes', '/admin_only=no', '/dlt_null=yes')
        ${stderrLog} = Join-Path ${logDir} "npcap-install-stderr.log"
        ${stdoutLog} = Join-Path ${logDir} "npcap-install-stdout.log"
        ${p} = Start-Process -FilePath ${installerPath} -ArgumentList ${npcapArgs} -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput ${stdoutLog} -RedirectStandardError ${stderrLog}
        Write-NpcapLog ("Installer PID: {0}; waiting up to 300s..." -f ${p}.Id)
        ${finished} = ${p}.WaitForExit(300000)
        try { ${p}.Refresh() } catch {}
        if (-not ${finished}) {
            try { ${p}.Kill() } catch {}
            throw "Npcap installer timed out after 300s (process killed)."
        }
        Write-NpcapLog ("Npcap installer exited. ExitCode={0}" -f ${p}.ExitCode)
        if ($null -ne ${p}.ExitCode -and ${p}.ExitCode -ne 0) {
            throw ("Npcap installer exited with code {0}" -f ${p}.ExitCode)
        }
    }

    # --- Verify service + driver are in place ---
    ${svc} = Get-Service -Name 'npcap' -ErrorAction SilentlyContinue
    if ($null -eq ${svc}) {
        throw "Npcap service not registered after install."
    }
    ${driver} = 'C:\Windows\System32\Npcap\npcap.sys'
    if (-not (Test-Path -LiteralPath ${driver})) {
        Write-NpcapLog ("[WARN] Npcap driver file not found at {0}" -f ${driver})
    }
    if (${svc}.Status -ne 'Running') {
        try { Start-Service -Name 'npcap' -ErrorAction Stop } catch { Write-NpcapLog ("[WARN] Start-Service npcap failed: {0}" -f $_.Exception.Message) }
    }
    Write-NpcapLog ("Npcap service state: {0} StartType={1}" -f ${svc}.Status, ${svc}.StartType)

    # --- npcapwatchdog scheduled task (mastw parity) ---
    # mastw runs a Ready task '\npcapwatchdog' that invokes 'C:\Program Files\Npcap\CheckStatus.bat'.
    # CheckStatus.bat ships with Npcap; we register the task only if the file exists.
    ${checkBat} = 'C:\Program Files\Npcap\CheckStatus.bat'
    if (Test-Path -LiteralPath ${checkBat}) {
        ${taskName} = 'npcapwatchdog'
        ${existingTask} = Get-ScheduledTask -TaskName ${taskName} -ErrorAction SilentlyContinue
        if ($null -eq ${existingTask}) {
            Write-NpcapLog "Registering scheduled task 'npcapwatchdog' (matches mastw)."
            ${action} = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ("/c `"{0}`"" -f ${checkBat})
            ${trigger} = New-ScheduledTaskTrigger -AtStartup
            ${principal} = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
            ${settings} = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
            Register-ScheduledTask -TaskName ${taskName} -Action ${action} -Trigger ${trigger} -Principal ${principal} -Settings ${settings} | Out-Null
            Write-NpcapLog "Registered task 'npcapwatchdog'."
        } else {
            Write-NpcapLog "Scheduled task 'npcapwatchdog' already present; skipping."
        }
    } else {
        Write-NpcapLog ("[WARN] CheckStatus.bat not found at {0}; skipping npcapwatchdog task." -f ${checkBat})
    }

    Write-NpcapLog "Npcap installation completed successfully."
    exit 0
}
catch {
    ${errorMsg} = ("Npcap installation failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
