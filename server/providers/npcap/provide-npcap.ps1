param(
    [string]${AssetsRoot} = "."
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

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-npcap.ps1 started (verify-only)." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# --- Install moved to bootstrap-winrm.ps1 ---
#
# Npcap registers a kernel driver. Under a WinRM network logon the calling
# user has a filtered NTLM token (BUILTIN\Administrators stripped from the
# effective groups), so the driver-install step silently no-ops. The previous
# workaround (run the installer as SYSTEM via a scheduled task + pre-trust the
# publisher cert) still could not get past the free Npcap installer's
# InstallOptions page, which has no working silent mode on Session 0 (the /S
# and feature flags are OEM-edition-only; see the 2026-05-27 DECISIONS entry).
#
# Npcap is now installed by client/bootstrap-winrm.ps1, which runs
# interactively as a full (unfiltered) admin token, so the operator clicks
# through the installer GUI once. This provider is therefore reduced to a
# post-bootstrap safety check: assert the service/driver are present (fail
# loud if bootstrap was skipped) and (re)register the npcapwatchdog scheduled
# task for mastw parity.

# Elevation status at startup (kept for triage continuity with older logs).
${id}     = [System.Security.Principal.WindowsIdentity]::GetCurrent()
${princ}  = New-Object System.Security.Principal.WindowsPrincipal(${id})
${isAdm}  = ${princ}.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
Write-NpcapLog ("ELEVATION user={0} isAdmin={1} authType={2}" -f ${id}.Name, ${isAdm}, ${id}.AuthenticationType)

try {
    # --- Assert service + driver are in place (installed by bootstrap) ---
    ${svc} = Get-Service -Name 'npcap' -ErrorAction SilentlyContinue
    if ($null -eq ${svc}) {
        throw ("Npcap service not registered. Npcap is installed by " +
               "client\bootstrap-winrm.ps1 (run interactively as admin before provisioning); " +
               "this unit appears to have skipped that step.")
    }
    # The kernel driver lives at System32\drivers\npcap.sys; System32\Npcap\
    # holds only the user-mode helpers. Accept either so a correctly installed
    # driver is not reported missing.
    ${driverCandidates} = @('C:\Windows\System32\drivers\npcap.sys', 'C:\Windows\System32\Npcap\npcap.sys')
    ${driver} = ${driverCandidates} | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not ${driver}) {
        Write-NpcapLog ("[WARN] Npcap driver file (npcap.sys) not found in {0}" -f (${driverCandidates} -join ' or '))
    } else {
        Write-NpcapLog ("Npcap driver present: {0}" -f ${driver})
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

    Write-NpcapLog "Npcap presence check completed successfully."
    exit 0
}
catch {
    ${errorMsg} = ("Npcap presence check failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
