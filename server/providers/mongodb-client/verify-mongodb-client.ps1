#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\Program Files\MongoDB'
)

# Verify the MongoDB client tools, and record which Compass the unit is actually
# running.
#
# The version report lives here rather than in the provider because the provider
# does not run on a steady-state unit -- its top guard skips the whole body once
# mongosh and the Compass wrapper exist. A unit that updated Compass after
# provisioning is exactly the case the provider never sees, so verify is the only
# pass that observes it. Compass's self-updating is accepted, not suppressed; a
# drifted version is reported and does NOT fail the module. See
# docs/decisions/2026-08-23-compass-updates-itself-so-the-report-follows-the-unit.md
#
# Replaces the inline one-liner that was in module.json's "verify" key; same
# mongosh check, same log and smoke-marker paths.
$ErrorActionPreference = 'Stop'

$mastLogDot = Join-Path $PSScriptRoot 'mast-log.ps1'
if (-not (Test-Path $mastLogDot)) { $mastLogDot = Join-Path $PSScriptRoot '..\..\lib\mast-log.ps1' }
. $mastLogDot
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts probe optional properties

$compassAppDot = Join-Path $PSScriptRoot 'compass-app.ps1'
if (-not (Test-Path $compassAppDot)) { throw "compass-app.ps1 not found beside verify-mongodb-client.ps1." }
. $compassAppDot

$verifyLog = Get-MastVerifyLog -Module 'mongodb-client'
function W { param([string]$Line) Add-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Line) }
Set-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] verify-mongodb-client.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$fail = @()

# --- mongosh: the check this module has always made ---
$mongosh = Get-ChildItem -LiteralPath $InstallRoot -Recurse -Filter 'mongosh.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
if ($mongosh) {
    W ("mongosh: {0}" -f $mongosh)
    try {
        $shellVersion = (& $mongosh --nodb --eval 'print(version())' 2>&1 | Select-Object -Last 1)
        W ("mongosh version: {0}" -f ([string]$shellVersion).Trim())
    } catch {
        $fail += "mongosh ran but did not report a version: $($_.Exception.Message)"
    }
} else {
    $fail += "mongosh.exe not found under $InstallRoot"
}

# --- Compass: report the live build, and the drift against what we ship ---
$compassRoot = Join-Path $env:LOCALAPPDATA 'MongoDBCompass'
if (Test-Path -LiteralPath $compassRoot) {
    $app = Get-MastCompassApp -CompassRoot $compassRoot
    $pin = Get-MastCompassPin -AssetsRoot $PSScriptRoot

    W ("compass builds on disk: {0}" -f $(
        if ($app.All.Count -gt 0) {
            (($app.All | ForEach-Object { "{0}{1}" -f $_.Name, $(if ($_.IsDead) { ' (dead)' } else { '' }) }) -join ', ')
        } else { '<none>' }))
    W ("compass live version: {0}" -f $(if ($app.Version) { $app.Version } else { '<unknown>' }))
    W ("compass installer version: {0}" -f $(if ($pin.Version) { $pin.Version } else { '<installer not staged>' }))

    if ($app.Version -and $pin.Version) {
        if ($app.Version -eq $pin.Version) {
            W 'compass drift: none'
        } else {
            # Not a failure: the updater is deliberately left enabled, so the
            # unit outrunning the asset is the expected steady state.
            W ("compass drift: SELF-UPDATED {0} -> {1}" -f $pin.Version, $app.Version)
        }
    }
    foreach ($s in $app.Superseded) { W ("compass superseded build present: {0}{1}" -f $s.Name, $(if ($s.IsDead) { ' (dead, Squirrel will remove it)' } else { '' })) }
} else {
    W 'compass: not installed on this unit'
}

if ($fail.Count -eq 0) {
    W 'PASS mongodb-client'
    Write-MastSmokeOk -Module 'mongodb-client' | Out-Null
    exit 0
}

W ('FAIL ' + ($fail -join '; '))
exit 1
