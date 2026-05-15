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
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$LogFile
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$timestamp | $Message" | Tee-Object -FilePath $LogFile -Append
}
