#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\Program Files\SAOImageDS9"
)

# Verify SAOImage DS9: ds9.exe present AND .fits associated with DS9 (not ASI Studio).
$ErrorActionPreference = 'Stop'
$mastLogDot = Join-Path $PSScriptRoot 'mast-log.ps1'
if (-not (Test-Path $mastLogDot)) { $mastLogDot = Join-Path $PSScriptRoot '..\..\lib\mast-log.ps1' }
. $mastLogDot
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts probe optional properties
$verifyLog = Get-MastVerifyLog -Module 'ds9'

function W { param([string]$Line) Add-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Line) }
Set-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] verify-ds9.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$fail = @()

# 1) ds9.exe extracted.
$ds9Exe = Join-Path $InstallRoot 'ds9.exe'
if (Test-Path -LiteralPath $ds9Exe) {
    $ver = ''
    try { $ver = (Get-Item -LiteralPath $ds9Exe).VersionInfo.ProductVersion } catch { }
    W ("ds9.exe present at {0} (ProductVersion={1})" -f $ds9Exe, $ver)
} else {
    $fail += "ds9.exe not found at $ds9Exe"
    if (Test-Path -LiteralPath $InstallRoot) {
        W ("--- {0} contents ---" -f $InstallRoot)
        Get-ChildItem -LiteralPath $InstallRoot -ErrorAction SilentlyContinue | Select-Object -First 20 | ForEach-Object { W ("  {0,12} {1}" -f $_.Length, $_.Name) }
    } else {
        W ("  ({0} does not exist; DS9 extract likely never ran)" -f $InstallRoot)
    }
}

# 2) FITS association points at DS9 (machine-wide HKLM\Software\Classes).
$progId = 'SAOImageDS9.fits'
$extProg = (Get-ItemProperty -Path 'HKLM:\Software\Classes\.fits' -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
W ("HKLM .fits -> '{0}' (expect '{1}')" -f $extProg, $progId)
if ($extProg -ne $progId) { $fail += ".fits not associated with $progId (got '$extProg')" }

$cmd = (Get-ItemProperty -Path "HKLM:\Software\Classes\$progId\shell\open\command" -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
W ("$progId open command: {0}" -f $cmd)
if (-not $cmd -or $cmd -notmatch 'ds9\.exe') { $fail += "$progId open command does not invoke ds9.exe" }

if ($fail.Count -eq 0) {
    W 'PASS ds9.exe present and .fits associated with DS9'
    Write-MastSmokeOk -Module 'ds9' | Out-Null
    exit 0
}

W ('FAIL ' + ($fail -join '; '))
exit 1
