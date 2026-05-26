param(
    [string]${AssetsRoot} = ".",
    [string]${InstallerPattern} = "npcap-*.exe"
)

${ErrorActionPreference} = "Stop"

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}

# Import provisioning.psm1 (provides Invoke-ExeAsSystem for the
# WinRM-filtered-token workaround that lets us install the npcap kernel
# driver). Two-path fallback so this works both from staging and dev.
try {
    ${provLocal}  = Join-Path ${PSScriptRoot} 'provisioning.psm1'
    ${provGlobal} = Join-Path ${PSScriptRoot} '..\..\lib\provisioning.psm1'
    if      (Test-Path -LiteralPath ${provLocal})  { Import-Module ${provLocal}  -Force -DisableNameChecking -ErrorAction Stop }
    elseif  (Test-Path -LiteralPath ${provGlobal}) { Import-Module ${provGlobal} -Force -DisableNameChecking -ErrorAction Stop }
    else    { throw "provisioning.psm1 not found next to script or in ..\..\lib\" }
} catch {
    throw ("Failed to import provisioning.psm1: {0}" -f $_.Exception.Message)
}

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

# Elevation status at startup. Npcap registers a kernel driver, which requires
# a token with BUILTIN\Administrators in its effective groups. Under a WinRM
# network logon the admin group is often filtered out of the token even when
# the user is an Administrator, and the driver-install step silently no-ops.
# Logging this up front means a missing-service failure later has a known
# first-stop-to-look.
${id}     = [System.Security.Principal.WindowsIdentity]::GetCurrent()
${princ}  = New-Object System.Security.Principal.WindowsPrincipal(${id})
${isAdm}  = ${princ}.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
Write-NpcapLog ("ELEVATION user={0} isAdmin={1} authType={2} (driver install needs isAdmin=True)" -f ${id}.Name, ${isAdm}, ${id}.AuthenticationType)

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

        # Pre-trust the Authenticode publisher of npcap.exe before kicking the
        # installer. Reason: even running as SYSTEM, the npcap installer drops
        # a kernel driver, and Windows pops a "Do you trust this publisher?"
        # dialog on Session 0 the FIRST time it sees an unfamiliar driver
        # publisher. /S suppresses the *NSIS* UI but does NOT suppress that
        # Windows-level driver-trust prompt. Session 0 is non-interactive, so
        # the prompt never dismisses and the installer hangs forever (run #10:
        # SYSTEM task ran the full 15-min budget then was killed at -2).
        #
        # Fix: extract the Authenticode signer cert from npcap-*.exe and add
        # it to the machine TrustedPublisher store BEFORE running the installer.
        # Subsequent driver installs from that publisher then proceed without
        # the prompt. Same pattern the 'stage' provider uses for Standa's
        # standa-driver-publisher.cer.
        Write-NpcapLog "Extracting Authenticode publisher cert from npcap installer for TrustedPublisher pre-trust..."
        try {
            ${sig} = Get-AuthenticodeSignature -FilePath ${installerPath} -ErrorAction Stop
            if ($null -eq ${sig}.SignerCertificate) {
                Write-NpcapLog ("[WARN] Npcap installer has no Authenticode signer; driver-trust prompt may still hang the install.")
            } else {
                ${signer} = ${sig}.SignerCertificate
                Write-NpcapLog ("Publisher: {0} (thumbprint {1})" -f ${signer}.Subject, ${signer}.Thumbprint)
                ${store} = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher', 'LocalMachine')
                ${store}.Open('ReadWrite')
                try { ${store}.Add(${signer}) } finally { ${store}.Close() }
                Write-NpcapLog "Added npcap publisher to LocalMachine\TrustedPublisher."
            }
        } catch {
            Write-NpcapLog ("[WARN] Could not pre-trust npcap publisher: {0}" -f $_.Exception.Message)
        }

        # NSIS-style silent install with feature flags chosen to match mastw:
        #   /S                    - silent (NSIS UI suppression)
        #   /loopback_support=yes - install Npcap Loopback Adapter (capture from localhost)
        #   /winpcap_mode=yes     - WinPcap-compatible API for legacy callers
        #   /admin_only=no        - allow non-admin processes to capture
        #   /dlt_null=yes         - DLT_NULL on the loopback adapter (matches mastw)
        #
        # Run via SYSTEM scheduled task -- under WinRM the calling user has a
        # filtered NTLM token (BUILTIN\Admins stripped from effective groups)
        # and the npcap installer needs an unfiltered admin token to register
        # its kernel driver. Combined with the publisher pre-trust above, this
        # gives the installer everything it needs to run unattended.
        ${argString} = '/S /loopback_support=yes /winpcap_mode=yes /admin_only=no /dlt_null=yes'
        Write-NpcapLog ("Running Npcap installer as SYSTEM (scheduled task) with args: {0}" -f ${argString})
        ${rc} = Invoke-ExeAsSystem -Executable ${installerPath} -Arguments ${argString} `
            -TimeoutMinutes 15 -TaskNamePrefix 'MAST-NpcapInstall'
        Write-NpcapLog ("Npcap installer exited. ExitCode={0}" -f ${rc})
        if (${rc} -ne 0 -and ${rc} -ne 3010) {
            throw ("Npcap installer exited with code {0}" -f ${rc})
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
