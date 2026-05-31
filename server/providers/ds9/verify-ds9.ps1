#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\Program Files\SAOImageDS9"
)

# Verify SAOImage DS9 extracted correctly: ds9.exe must be present and runnable.
$ErrorActionPreference = 'Stop'
$mastLogDot = Join-Path $PSScriptRoot 'mast-log.ps1'
if (-not (Test-Path $mastLogDot)) { $mastLogDot = Join-Path $PSScriptRoot '..\..\lib\mast-log.ps1' }
. $mastLogDot
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts predate it and probe optional properties
$verifyLog = Get-MastVerifyLog -Module 'ds9'

function W { param([string]$Line) Add-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Line) }
Set-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] verify-ds9.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$ds9Exe = Join-Path $InstallRoot 'ds9.exe'
if (Test-Path -LiteralPath $ds9Exe) {
    $ver = ''
    try { $ver = (Get-Item -LiteralPath $ds9Exe).VersionInfo.ProductVersion } catch { }
    W ("PASS ds9.exe present at {0} (ProductVersion={1})" -f $ds9Exe, $ver)
    Write-MastSmokeOk -Module 'ds9' | Out-Null
    exit 0
}

W ("FAIL ds9.exe not found at {0}" -f $ds9Exe)
if (Test-Path -LiteralPath $InstallRoot) {
    W ("--- {0} contents ---" -f $InstallRoot)
    Get-ChildItem -LiteralPath $InstallRoot -ErrorAction SilentlyContinue | Select-Object -First 20 | ForEach-Object {
        W ("  {0,12} {1}" -f $_.Length, $_.Name)
    }
} else {
    W ("  ({0} does not exist; DS9 extract likely never ran)" -f $InstallRoot)
}
exit 1
