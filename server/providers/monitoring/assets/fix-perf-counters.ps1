<#
.SYNOPSIS
    Fixes broken Windows performance counter enumeration on MAST IoT units.

.DESCRIPTION
    On Windows 10 IoT Enterprise LTSC 2021 images deployed as MAST units, certain
    perf counter providers (.NETFramework, BITS, ...) have broken Open procedures
    because their supporting .ini files were not deployed. When Perflib enumerates
    counters for PDH consumers (typeperf, Get-Counter, WMI perf classes, and
    windows_exporter), these failing Open calls truncate the enumeration result,
    silently dropping core OS counter sets (Memory, Processor, System, Process).

    Symptoms:
        - typeperf "\Memory\Available Bytes" -sc 1   -> "No valid counters."
        - (Get-Counter -ListSet *).Count             -> ~8 instead of ~190+
        - Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -> "Invalid class"
        - windows_exporter exposes only GPU/Hyper-V metrics

    Diagnostic:
        - Application event log, Microsoft-Windows-Perflib, IDs 1008/1010/1023

    Fix:
        - Disable Performance Counters flag on each broken provider's registry key
        - Rebuild perf counter cache (lodctr /R)
        - Resync WMI ADAP (wmiadap /f)
        - Restart winmgmt so consumers re-initialize PDH catalog
        - Restart windows_exporter so Prometheus sees the full metric set

.PARAMETER WindowsExporterServiceName
    Service name of windows_exporter. Default: 'windows_exporter'.
    Set to $null or empty to skip the exporter restart step.

.PARAMETER SkipVerification
    Skip the post-fix verification phase. Default: $false.

.PARAMETER Force
    Run the fix even if the system already appears healthy. Default: $false.

.EXAMPLE
    .\Fix-MastPerfCounters.ps1
    Run with defaults. Idempotent — safe to run on already-fixed units.

.EXAMPLE
    .\Fix-MastPerfCounters.ps1 -WindowsExporterServiceName 'prometheus-windows-exporter'
    Use a non-default exporter service name.

.NOTES
    Must be run as Administrator.
    Logs to C:\ProgramData\MAST\provisioning\Fix-MastPerfCounters-<timestamp>.log
#>

[CmdletBinding()]
param(
    [string]$WindowsExporterServiceName = 'windows_exporter',
    [switch]$SkipVerification,
    [switch]$Force
)

#----------------------------------------------------------------------
# Setup
#----------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'

# Logging
$LogDir = 'C:\ProgramData\MAST\provisioning'
if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}
$LogFile = Join-Path $LogDir ("Fix-MastPerfCounters-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','STEP')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'OK'    { 'Green' }
        'STEP'  { 'Cyan' }
        default { 'White' }
    }
    Write-Host $line -ForegroundColor $color
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

#----------------------------------------------------------------------
# Phase 0: Preflight
#----------------------------------------------------------------------

Write-Log "Fix-MastPerfCounters v$ScriptVersion starting on $env:COMPUTERNAME" -Level STEP
Write-Log "Log file: $LogFile"

if (-not (Test-Admin)) {
    Write-Log "Must run as Administrator." -Level ERROR
    exit 2
}

$os = Get-CimInstance Win32_OperatingSystem
Write-Log "OS: $($os.Caption) (build $($os.BuildNumber)), SKU $($os.OperatingSystemSKU)"

#----------------------------------------------------------------------
# Phase 1: Diagnose
#----------------------------------------------------------------------

Write-Log "Phase 1: Diagnosing perf counter state" -Level STEP

# Count visible counter sets — healthy is ~190+, broken is ~8
$listSetCount = 0
try {
    $listSetCount = (Get-Counter -ListSet * -ErrorAction Stop).Count
} catch {
    Write-Log "Get-Counter -ListSet * failed: $_" -Level WARN
}
Write-Log "Currently visible counter sets: $listSetCount"

# Try the canonical Memory counter
$memoryWorks = $false
try {
    $null = Get-Counter -Counter '\Memory\Available Bytes' -ErrorAction Stop
    $memoryWorks = $true
} catch {
    # expected on broken systems
}
Write-Log "Memory counter query works: $memoryWorks"

# Find failing providers in event log (last 7 days to keep query fast)
Write-Log "Scanning Application event log for Perflib failures..."
$failingProviders = @()
try {
    $events = Get-WinEvent -FilterHashtable @{
        LogName      = 'Application'
        ProviderName = 'Microsoft-Windows-Perflib'
        Id           = 1008,1010,1023
        StartTime    = (Get-Date).AddDays(-7)
    } -ErrorAction SilentlyContinue

    if ($events) {
        # Extract service names from messages like:
        # "The Open procedure for service "BITS" in DLL ..."
        $regex = 'service "([^"]+)"'
        $failingProviders = $events |
            ForEach-Object {
                if ($_.Message -match $regex) { $matches[1] }
            } |
            Where-Object { $_ } |
            Sort-Object -Unique
    }
} catch {
    Write-Log "Event log query failed: $_" -Level WARN
}

if ($failingProviders.Count -gt 0) {
    Write-Log "Failing providers detected: $($failingProviders -join ', ')" -Level WARN
} else {
    Write-Log "No Perflib 1008/1010/1023 events in last 7 days." -Level OK
}

# Decide whether to proceed
$systemHealthy = ($listSetCount -ge 100) -and $memoryWorks
if ($systemHealthy -and -not $Force) {
    Write-Log "System appears healthy ($listSetCount counter sets, Memory works)." -Level OK
    Write-Log "Skipping fix. Use -Force to apply anyway." -Level OK
    exit 0
}

#----------------------------------------------------------------------
# Phase 2: Fix
#----------------------------------------------------------------------

Write-Log "Phase 2: Applying fix" -Level STEP

# Providers known to be broken on the standard MAST IoT image.
# We always disable these, even if not seen in the event log, because:
#   (a) events older than 7 days won't show up
#   (b) the broken providers haven't been queried since boot won't have logged events yet
$knownBrokenProviders = @('.NETFramework', 'BITS')

# Union of known + detected
$providersToDisable = @($knownBrokenProviders + $failingProviders) | Sort-Object -Unique

foreach ($provider in $providersToDisable) {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$provider\Performance"
    if (-not (Test-Path $regPath)) {
        Write-Log "Provider '$provider' has no Performance subkey — skipping." -Level INFO
        continue
    }
    try {
        $current = (Get-ItemProperty -Path $regPath -Name 'Disable Performance Counters' -ErrorAction SilentlyContinue).'Disable Performance Counters'
        if ($current -eq 1) {
            Write-Log "Provider '$provider' already disabled." -Level INFO
        } else {
            Set-ItemProperty -Path $regPath -Name 'Disable Performance Counters' -Value 1 -Type DWord
            Write-Log "Disabled provider '$provider'." -Level OK
        }
    } catch {
        Write-Log "Failed to disable '$provider': $_" -Level ERROR
    }
}

# Rebuild perf counter cache from registered providers
Write-Log "Running lodctr /R..."
$lodctr = & lodctr.exe /R 2>&1
Write-Log "lodctr output: $lodctr"

# Resync WMI ADAP so dynamic Win32_PerfFormattedData_* classes regenerate
Write-Log "Running wmiadap /f..."
$wmiadap = & wmiadap.exe /f 2>&1
Write-Log "wmiadap output: $($wmiadap -join ' ')"

# Restart winmgmt so PDH consumers re-init from current catalog.
# IP Helper depends on winmgmt and will be stopped too; restart it after.
Write-Log "Restarting Windows Management Instrumentation service (winmgmt)..."
try {
    Stop-Service -Name winmgmt -Force -ErrorAction Stop
    Start-Service -Name winmgmt -ErrorAction Stop
    Write-Log "winmgmt restarted." -Level OK
} catch {
    Write-Log "winmgmt restart failed: $_" -Level ERROR
}

# Restart dependent services that net stop /y took down
foreach ($depService in @('iphlpsvc')) {
    try {
        $svc = Get-Service -Name $depService -ErrorAction Stop
        if ($svc.Status -ne 'Running') {
            Start-Service -Name $depService
            Write-Log "Restarted dependent service '$depService'." -Level OK
        }
    } catch {
        Write-Log "Could not restart '$depService': $_" -Level WARN
    }
}

# Restart windows_exporter so it picks up the now-complete counter catalog
if ($WindowsExporterServiceName) {
    try {
        $exporter = Get-Service -Name $WindowsExporterServiceName -ErrorAction Stop
        Write-Log "Restarting $WindowsExporterServiceName (was $($exporter.Status))..."
        if ($exporter.Status -eq 'Running') {
            Stop-Service -Name $WindowsExporterServiceName -Force
        }
        Start-Service -Name $WindowsExporterServiceName
        Write-Log "$WindowsExporterServiceName restarted." -Level OK
    } catch [Microsoft.PowerShell.Commands.ServiceCommandException] {
        Write-Log "windows_exporter service '$WindowsExporterServiceName' not found — skipping restart." -Level INFO
    } catch {
        Write-Log "Could not restart '$WindowsExporterServiceName': $_" -Level WARN
    }
}

#----------------------------------------------------------------------
# Phase 3: Verify
#----------------------------------------------------------------------

if ($SkipVerification) {
    Write-Log "Verification skipped (-SkipVerification)." -Level INFO
    Write-Log "Done. See $LogFile" -Level OK
    exit 0
}

Write-Log "Phase 3: Verifying fix" -Level STEP

# Note: this PowerShell session itself cached PDH state at startup, so verification
# from within this process may not reflect the fix immediately. We start a fresh
# child PowerShell process to verify.
$verifyScript = @'
$ErrorActionPreference = 'Stop'
$result = [ordered]@{}
try {
    $result.ListSetCount = (Get-Counter -ListSet * -ErrorAction Stop).Count
} catch {
    $result.ListSetCount = -1
    $result.ListSetError = $_.Exception.Message
}
try {
    $sample = Get-Counter -Counter '\Memory\Available Bytes' -ErrorAction Stop
    $result.MemoryAvailableBytes = [int64]$sample.CounterSamples[0].CookedValue
} catch {
    $result.MemoryAvailableBytes = -1
    $result.MemoryError = $_.Exception.Message
}
try {
    $wmi = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
    $result.WmiMemoryClassWorks = $true
    $result.WmiCommittedBytes = [int64]$wmi.CommittedBytes
} catch {
    $result.WmiMemoryClassWorks = $false
    $result.WmiError = $_.Exception.Message
}
$result | ConvertTo-Json -Compress
'@

$verifyOut = & powershell.exe -NoProfile -Command $verifyScript 2>&1
Write-Log "Verification output: $verifyOut"

try {
    $verify = $verifyOut | ConvertFrom-Json
    $pass = $true
    if ($verify.ListSetCount -lt 100) {
        Write-Log "FAIL: ListSet count is $($verify.ListSetCount), expected >=100" -Level ERROR
        $pass = $false
    } else {
        Write-Log "OK: ListSet count = $($verify.ListSetCount)" -Level OK
    }
    if ($verify.MemoryAvailableBytes -le 0) {
        Write-Log "FAIL: \Memory\Available Bytes query failed" -Level ERROR
        $pass = $false
    } else {
        Write-Log ("OK: Memory Available = {0:N0} bytes ({1:N2} GB)" -f $verify.MemoryAvailableBytes, ($verify.MemoryAvailableBytes/1GB)) -Level OK
    }
    if (-not $verify.WmiMemoryClassWorks) {
        Write-Log "FAIL: Win32_PerfFormattedData_PerfOS_Memory not accessible" -Level ERROR
        $pass = $false
    } else {
        Write-Log "OK: WMI perf class works (Committed: $([math]::Round($verify.WmiCommittedBytes/1GB,2)) GB)" -Level OK
    }
    if ($pass) {
        Write-Log "All verification checks passed. mast unit is ready." -Level OK
        Write-Log "Log: $LogFile" -Level OK
        exit 0
    } else {
        Write-Log "Verification failed. Manual investigation required." -Level ERROR
        Write-Log "Check Application event log for new Microsoft-Windows-Perflib events." -Level ERROR
        Write-Log "Log: $LogFile" -Level ERROR
        exit 1
    }
} catch {
    Write-Log "Could not parse verification output: $_" -Level ERROR
    exit 1
}
