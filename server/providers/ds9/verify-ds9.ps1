#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\Program Files\SAOImageDS9"
)

# Verify SAOImage DS9 extracted correctly: ds9.exe must be present and runnable.
$ErrorActionPreference = 'Stop'
$logRoot   = Join-Path (Join-Path $env:SystemDrive 'MAST') 'logs'
$verifyLog = Join-Path $logRoot 'verify\ds9-verify.log'
$smokeFile = Join-Path $logRoot 'smoke\ds9-smoke.txt'
$null = New-Item -ItemType Directory -Force -Path (Split-Path $verifyLog -Parent), (Split-Path $smokeFile -Parent) -ErrorAction SilentlyContinue

function W { param([string]$Line) Add-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Line) }
Set-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] verify-ds9.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$ds9Exe = Join-Path $InstallRoot 'ds9.exe'
if (Test-Path -LiteralPath $ds9Exe) {
    $ver = ''
    try { $ver = (Get-Item -LiteralPath $ds9Exe).VersionInfo.ProductVersion } catch { }
    W ("PASS ds9.exe present at {0} (ProductVersion={1})" -f $ds9Exe, $ver)
    Set-Content -Path $smokeFile -Encoding ASCII -Value 'ds9_ok'
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
