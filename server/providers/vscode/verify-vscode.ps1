#requires -Version 5.1
[CmdletBinding()]
param()

# Verify VS Code: Code.exe present AND the bundled extensions (ms-python.python,
# ms-python.debugpy) are installed in the running user's profile. Provisioning
# runs as the mast account, so $env:USERPROFILE is mast's and the extensions live
# under <USERPROFILE>\.vscode\extensions.
$ErrorActionPreference = 'Stop'
$mastLogDot = Join-Path $PSScriptRoot 'mast-log.ps1'
if (-not (Test-Path $mastLogDot)) { $mastLogDot = Join-Path $PSScriptRoot '..\..\lib\mast-log.ps1' }
. $mastLogDot
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts probe optional properties
$verifyLog = Get-MastVerifyLog -Module 'vscode'

function W { param([string]$Line) Add-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Line) }
Set-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] verify-vscode.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$fail = @()

# 1) Code.exe present (UserSetup LOCALAPPDATA or system install).
$userExe = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'
$sysExe  = 'C:\Program Files\Microsoft VS Code\Code.exe'
if ((Test-Path -LiteralPath $userExe) -or (Test-Path -LiteralPath $sysExe)) {
    W ("Code.exe present ({0})" -f $(if (Test-Path -LiteralPath $userExe) { $userExe } else { $sysExe }))
} else {
    $fail += 'Code.exe not found (UserSetup or system path)'
}

# 2) Required extensions present in this user's profile.
$extDir = Join-Path $env:USERPROFILE '.vscode\extensions'
foreach ($want in 'ms-python.python', 'ms-python.debugpy') {
    $hit = Get-ChildItem -LiteralPath $extDir -Directory -Filter ("{0}-*" -f $want) -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) {
        W ("extension present: {0}" -f $hit.Name)
    } else {
        $fail += "$want not installed under $extDir"
    }
}

if ($fail.Count -eq 0) {
    W 'PASS Code.exe present and ms-python.python + ms-python.debugpy installed'
    Write-MastSmokeOk -Module 'vscode' | Out-Null
    exit 0
}

W ('FAIL ' + ($fail -join '; '))
exit 1
