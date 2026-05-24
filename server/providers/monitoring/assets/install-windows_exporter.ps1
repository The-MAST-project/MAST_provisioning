<#
.SYNOPSIS
    Installs windows_exporter via the official MSI for MAST IoT unit provisioning.

.DESCRIPTION
    Downloads (or reuses a cached copy of) the official windows_exporter MSI
    from the prometheus-community GitHub releases and installs it with an
    extensive list of collectors enabled. The MSI creates a Windows service
    set to start automatically at boot, opens TCP 9182 in Windows Firewall,
    and runs as LocalSystem.

    Idempotent: if the same version is already installed, the script verifies
    the service is running and exits. If a different version is installed,
    it is uninstalled first and replaced.

.PARAMETER Version
    Version of windows_exporter to install. Default: '0.30.5'.

.PARAMETER ListenPort
    TCP port for the metrics endpoint. Default: 9182.

.PARAMETER EnabledCollectors
    Comma-separated list of collectors. Default is an extensive set
    appropriate for MAST/observatory monitoring (system health, network,
    storage, process inventory, scheduled tasks, time sync).

.PARAMETER CachePath
    Local cache for the MSI. Default: 'C:\ProgramData\MAST\provisioning\cache'.
    Pre-populate this directory for offline installs.

.PARAMETER Offline
    Skip download; require the MSI to already be in the cache.

.PARAMETER Force
    Reinstall even if the target version is already present.

.EXAMPLE
    .\Install-WindowsExporter.ps1

.EXAMPLE
    .\Install-WindowsExporter.ps1 -Version 0.30.5 -ListenPort 9182

.EXAMPLE
    # Offline / air-gapped:
    Copy-Item .\windows_exporter-0.30.5-amd64.msi C:\ProgramData\MAST\provisioning\cache\
    .\Install-WindowsExporter.ps1 -Offline

.NOTES
    Must be run as Administrator.
    Log: C:\ProgramData\MAST\provisioning\Install-WindowsExporter-<timestamp>.log
#>

[CmdletBinding()]
param(
    [string]$Version = '0.30.5',
    [int]   $ListenPort = 9182,
    [string]$EnabledCollectors = 'cpu,cpu_info,cs,logical_disk,physical_disk,memory,net,os,process,service,system,tcp,textfile,thermalzone,time,scheduled_task,terminal_services,smbclient,smb,dns,dhcp,iis,logon',
    [string]$CachePath = 'C:\ProgramData\MAST\provisioning\cache',
    [switch]$Offline,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'
$ServiceName = 'windows_exporter'

#----------------------------------------------------------------------
# Logging
#----------------------------------------------------------------------
$LogDir = 'C:\ProgramData\MAST\provisioning'
$null = New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue
$null = New-Item -Path $CachePath -ItemType Directory -Force -ErrorAction SilentlyContinue
$LogFile = Join-Path $LogDir ("Install-WindowsExporter-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK','STEP')][string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $line
    $color = @{ERROR='Red';WARN='Yellow';OK='Green';STEP='Cyan';INFO='White'}[$Level]
    Write-Host $line -ForegroundColor $color
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

#----------------------------------------------------------------------
# Preflight
#----------------------------------------------------------------------
Write-Log "Install-WindowsExporter v$ScriptVersion on $env:COMPUTERNAME" -Level STEP
Write-Log "Target version: $Version | port: $ListenPort"
Write-Log "Collectors: $EnabledCollectors"
Write-Log "Log: $LogFile"

if (-not (Test-Admin)) {
    Write-Log "Must run as Administrator." -Level ERROR
    exit 2
}

$arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { '386' }
$msiFileName = "windows_exporter-$Version-$arch.msi"
$msiCachePath = Join-Path $CachePath $msiFileName
$msiUrl = "https://github.com/prometheus-community/windows_exporter/releases/download/v$Version/$msiFileName"

#----------------------------------------------------------------------
# Phase 1: Check existing install
#----------------------------------------------------------------------
Write-Log "Phase 1: Checking existing installation" -Level STEP

$existingInstall = Get-ItemProperty `
    HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*,
    HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'windows.?exporter' } |
    Select-Object -First 1

if ($existingInstall) {
    Write-Log "Found existing install: $($existingInstall.DisplayName) v$($existingInstall.DisplayVersion)"
    if ($existingInstall.DisplayVersion -eq $Version -and -not $Force) {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Write-Log "Target version $Version already installed and service running. Nothing to do." -Level OK
            Write-Log "Use -Force to reinstall anyway." -Level INFO
            exit 0
        } else {
            Write-Log "Target version installed but service not running. Starting it..." -Level WARN
            Start-Service -Name $ServiceName
            Write-Log "Service started." -Level OK
            exit 0
        }
    }
    # Different version or -Force: uninstall first
    Write-Log "Uninstalling existing $($existingInstall.DisplayVersion) before installing $Version..." -Level WARN
    $uninstallString = $existingInstall.UninstallString
    # UninstallString is typically "MsiExec.exe /I{GUID}" — switch /I to /X for uninstall
    if ($uninstallString -match '\{[0-9A-Fa-f-]+\}') {
        $productCode = $matches[0]
        $uninstArgs = "/x $productCode /qn /norestart"
        Write-Log "Running: msiexec $uninstArgs"
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $uninstArgs -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
            Write-Log "Uninstall returned exit code $($p.ExitCode)" -Level ERROR
            exit 5
        }
        Write-Log "Uninstall complete." -Level OK
    } else {
        Write-Log "Could not extract product code from uninstall string: $uninstallString" -Level ERROR
        exit 5
    }
} else {
    Write-Log "No existing windows_exporter installation found."
}

#----------------------------------------------------------------------
# Phase 2: Acquire MSI
#----------------------------------------------------------------------
Write-Log "Phase 2: Acquiring MSI" -Level STEP

if (-not (Test-Path $msiCachePath)) {
    if ($Offline) {
        Write-Log "Offline mode: $msiCachePath not found and downloads disabled." -Level ERROR
        exit 3
    }
    Write-Log "Downloading $msiUrl"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiCachePath -UseBasicParsing
        $size = (Get-Item $msiCachePath).Length
        Write-Log ("Downloaded {0:N0} bytes to {1}" -f $size, $msiCachePath) -Level OK
    } catch {
        Write-Log "Download failed: $_" -Level ERROR
        if (Test-Path $msiCachePath) { Remove-Item $msiCachePath -Force }
        exit 4
    }
} else {
    $size = (Get-Item $msiCachePath).Length
    Write-Log ("Using cached MSI: {0} ({1:N0} bytes)" -f $msiCachePath, $size)
}

#----------------------------------------------------------------------
# Phase 3: Install
#----------------------------------------------------------------------
Write-Log "Phase 3: Installing MSI" -Level STEP

$installLog = Join-Path $LogDir ("msiexec-install-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
$msiArgs = @(
    '/i', "`"$msiCachePath`""
    '/quiet', '/norestart'
    '/l*v', "`"$installLog`""
    "ENABLED_COLLECTORS=$EnabledCollectors"
    "LISTEN_PORT=$ListenPort"
)
Write-Log "Running: msiexec $($msiArgs -join ' ')"
$p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
Write-Log "msiexec exited with code $($p.ExitCode)"
Write-Log "Detailed install log: $installLog"

# 0 = success, 3010 = success but reboot required
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
    Write-Log "Install failed. See $installLog" -Level ERROR
    exit 6
}
Write-Log "Install completed." -Level OK

#----------------------------------------------------------------------
# Phase 4: Verify
#----------------------------------------------------------------------
Write-Log "Phase 4: Verifying" -Level STEP

# Service
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Log "Service '$ServiceName' not found after install." -Level ERROR
    exit 7
}
Write-Log "Service: $($svc.Name) | StartType: $($svc.StartType) | Status: $($svc.Status)"
if ($svc.StartType -ne 'Automatic') {
    Write-Log "Setting service to Automatic startup..."
    Set-Service -Name $ServiceName -StartupType Automatic
}
if ($svc.Status -ne 'Running') {
    Write-Log "Starting service..."
    Start-Service -Name $ServiceName
}

# Wait briefly for the listener to come up
Start-Sleep -Seconds 3

# Metrics endpoint
$ok = $false
for ($i = 0; $i -lt 5; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$ListenPort/metrics" -UseBasicParsing -TimeoutSec 5
        if ($r.StatusCode -eq 200) {
            $lineCount = ($r.Content -split "`n").Count
            Write-Log "Metrics endpoint OK: http://localhost:$ListenPort/metrics ($lineCount lines)" -Level OK
            # Surface a few key series to confirm the right collectors fired
            $haveMemory = $r.Content -match 'windows_memory_'
            $haveCpu    = $r.Content -match 'windows_cpu_'
            $haveDisk   = $r.Content -match 'windows_logical_disk_'
            $haveOs     = $r.Content -match 'windows_os_'
            Write-Log ("Series present: memory={0} cpu={1} logical_disk={2} os={3}" -f $haveMemory,$haveCpu,$haveDisk,$haveOs) -Level OK
            $ok = $true
            break
        }
    } catch {
        Start-Sleep -Seconds 2
    }
}
if (-not $ok) {
    Write-Log "Metrics endpoint did not respond after install." -Level ERROR
    exit 8
}

Write-Log "windows_exporter v$Version installed and serving on port $ListenPort." -Level OK
Write-Log "Done." -Level OK
exit 0