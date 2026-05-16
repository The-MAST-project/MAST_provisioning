# Shared MAST logging paths under <SystemDrive>\MAST\logs (typically C:\MAST\logs).
# Dot-source from provisioning.psm1 or provider scripts. ASCII-only.

Set-StrictMode -Version Latest

function Get-MastLogsBase {
    [CmdletBinding()]
    param()
    return (Join-Path $env:SystemDrive 'MAST\logs')
}

function Get-MastLogSessionDir {
    [CmdletBinding()]
    param()
    $mastBase = Get-MastLogsBase
    $trimmed = $null
    if ($env:MAST_LOG_SESSION_DIR) {
        $trimmed = $env:MAST_LOG_SESSION_DIR.Trim()
    }
    if ($trimmed) {
        $null = New-Item -ItemType Directory -Path $trimmed -Force -ErrorAction SilentlyContinue
        return $trimmed
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $sessionDir = Join-Path $mastBase ('sessions\' + $stamp)
    $null = New-Item -ItemType Directory -Path $sessionDir -Force -ErrorAction SilentlyContinue
    $env:MAST_LOG_SESSION_DIR = $sessionDir
    return $sessionDir
}

function Get-MastSmokeDir {
    [CmdletBinding()]
    param()
    $d = Join-Path (Get-MastLogsBase) 'smoke'
    $null = New-Item -ItemType Directory -Path $d -Force -ErrorAction SilentlyContinue
    return $d
}

function Get-MastVerifyDir {
    [CmdletBinding()]
    param()
    $d = Join-Path (Get-MastLogsBase) 'verify'
    $null = New-Item -ItemType Directory -Path $d -Force -ErrorAction SilentlyContinue
    return $d
}

# ---------------------------------------------------------------------------
# Provisioning-server log paths (C:\MAST\logs\prov\)
# Dot-source this file in check-and-provision.ps1 instead of duplicating paths.
# ---------------------------------------------------------------------------

function Get-MastProvLogsBase {
    [CmdletBinding()]
    param()
    $d = Join-Path (Get-MastLogsBase) 'prov'
    $null = New-Item -ItemType Directory -Path $d -Force -ErrorAction SilentlyContinue
    return $d
}

function Get-MastProvSessionDir {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId)
    $d = Join-Path (Get-MastProvLogsBase) ('sessions\' + $RunId)
    $null = New-Item -ItemType Directory -Path $d -Force -ErrorAction SilentlyContinue
    return $d
}

function Get-MastProvActivityCsv {
    [CmdletBinding()]
    param()
    return (Join-Path (Get-MastProvLogsBase) 'activity.csv')
}

function Get-MastProvLastErrLog {
    [CmdletBinding()]
    param()
    return (Join-Path (Get-MastProvLogsBase) 'last-error.log')
}

# ---------------------------------------------------------------------------
# Shared timestamp and log-line helpers
# ---------------------------------------------------------------------------

function Now-Utc {
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Write-MastLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [Parameter(Mandatory)][string]$LogFile
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$timestamp | $Message" | Tee-Object -FilePath $LogFile -Append
}

# ---------------------------------------------------------------------------
# Status files under <SystemDrive>\MAST\status\ (typically C:\MAST\status).
# Co-located with logs and installed-manifest so every unit-side state file
# lives under one tree. Shared by the unit-side execute lease, availability
# state, and prov-server last-run heartbeat. All writers must go through
# Write-MastStatusFileAtomic so partial writes are never observed by readers.
# ---------------------------------------------------------------------------

function Get-MastStatusBase {
    [CmdletBinding()]
    param()
    $base = Join-Path $env:SystemDrive 'MAST\status'
    $null = New-Item -ItemType Directory -Path $base -Force -ErrorAction SilentlyContinue
    return $base
}

function Get-MastExecuteLeasePath {
    [CmdletBinding()]
    param()
    return (Join-Path (Get-MastStatusBase) 'execute-lease.json')
}

function Get-MastAvailabilityPath {
    [CmdletBinding()]
    param()
    return (Join-Path (Get-MastStatusBase) 'availability.json')
}

function Get-MastLastRunPath {
    [CmdletBinding()]
    param()
    return (Join-Path (Get-MastStatusBase) 'last-run.json')
}

function Write-MastStatusFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )
    $tmp = "$Path.tmp"
    $json = $Object | ConvertTo-Json -Depth 8
    Set-Content -Path $tmp -Value $json -Encoding ASCII -NoNewline
    Move-Item -Path $tmp -Destination $Path -Force
}
