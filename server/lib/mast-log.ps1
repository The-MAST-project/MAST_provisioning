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
# Per-module verify log + smoke marker helpers.
#
# Every verify-*.ps1 script shares the same boilerplate: write progress to
# <logs>\verify\<module>-verify.log and, on success, a marker to
# <logs>\smoke\<module>-smoke.txt. Use these instead of hardcoding
# "Join-Path (Join-Path $env:SystemDrive 'MAST') 'logs'" in each script.
# Both create their parent directory (via Get-MastVerifyDir/Get-MastSmokeDir).
# ---------------------------------------------------------------------------

function Get-MastVerifyLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Module)
    return (Join-Path (Get-MastVerifyDir) ($Module + '-verify.log'))
}

function Get-MastSmokeMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Module)
    return (Join-Path (Get-MastSmokeDir) ($Module + '-smoke.txt'))
}

function Write-MastSmokeOk {
    # Write the smoke marker for a passing step. Defaults the contents to
    # '<module>_ok'; pass -Value to override (e.g. a SKIP marker). Returns the
    # marker path. ASCII encoding: marker contents are always plain ASCII.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Module,
        [string]$Value
    )
    if (-not $Value) { $Value = ($Module + '_ok') }
    $path = Get-MastSmokeMarker -Module $Module
    Set-Content -Path $path -Value $Value -Encoding ASCII
    return $path
}

# ---------------------------------------------------------------------------
# Provisioning-server log paths (C:\MAST\logs\prov\)
# Dot-source this file in unit-side scripts and providers instead of duplicating paths.
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

function Get-UtcNow {
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

# ---------------------------------------------------------------------------
# Per-module reported facts under <SystemDrive>\MAST\status\facts\.
#
# The manifest records whether a module PASSED. Facts record what it FOUND --
# the things only the module's own scripts can know and the driver cannot derive
# from a payload hash: which Compass build a unit runs after Compass updated
# itself (#137), which Python resolved, what firmware a device reports.
# execute-mast-provisioning.ps1 folds them into installed-manifest.json, so the
# fleet report answers "what is actually on each unit" without an operator
# logging into every one of them.
#
# Facts are observations, never checks. Nothing here feeds fully_provisioned; a
# module that reports an unexpected fact still passes if its verify passed.
#
# ONE CALL PER MODULE: the file is REPLACED, not merged, so a module states its
# whole fact set at once. Merging would keep a fact alive after the code that
# produced it was deleted, which is the stale-annotation problem in another
# costume. Values stay scalar -- the manifest is written with
# ConvertTo-Json -Depth 6 and facts already sit four levels down.
# ---------------------------------------------------------------------------

function Get-MastFactsDir {
    [CmdletBinding()]
    param()
    $d = Join-Path (Get-MastStatusBase) 'facts'
    $null = New-Item -ItemType Directory -Path $d -Force -ErrorAction SilentlyContinue
    return $d
}

function Get-MastModuleFactsPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Module)
    return (Join-Path (Get-MastFactsDir) ($Module + '.json'))
}

function Write-MastModuleFacts {
    <#
    .SYNOPSIS
      Record what a module observed, for execute to fold into installed-manifest.json.
    .DESCRIPTION
      Stamps observed_at so a reader can tell facts left by an earlier run from
      facts gathered in the run that wrote the manifest -- a module whose verify
      did not run this pass contributes its previous observation, not a fresh one.
    .OUTPUTS
      The path written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Module,
        [Parameter(Mandatory)][hashtable]$Facts
    )
    $out = [ordered]@{}
    foreach ($k in @($Facts.Keys | Sort-Object)) { $out[[string]$k] = $Facts[$k] }
    $out['observed_at'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $path = Get-MastModuleFactsPath -Module $Module
    Write-MastStatusFileAtomic -Path $path -Object ([pscustomobject]$out)
    return $path
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
