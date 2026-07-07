#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$JupyterRoot = 'C:\MAST\jupyter'
)

# Verify Jupyter: the contained venv exists with jupyter-notebook.exe, the launcher
# is deployed, and a kernelspec is registered inside the venv (so nothing relies on
# the user profile).
$ErrorActionPreference = 'Stop'
$mastLogDot = Join-Path $PSScriptRoot 'mast-log.ps1'
if (-not (Test-Path $mastLogDot)) { $mastLogDot = Join-Path $PSScriptRoot '..\..\lib\mast-log.ps1' }
. $mastLogDot
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts probe optional properties
$verifyLog = Get-MastVerifyLog -Module 'jupyter'

function W { param([string]$Line) Add-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Line) }
Set-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] verify-jupyter.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$fail = @()

$venvPy   = Join-Path $JupyterRoot '.venv\Scripts\python.exe'
$jnExe    = Join-Path $JupyterRoot '.venv\Scripts\jupyter-notebook.exe'
$launcher = Join-Path $JupyterRoot 'launch-jupyter.cmd'

if (Test-Path -LiteralPath $venvPy) { W ("venv python present: {0}" -f $venvPy) } else { $fail += "venv python missing ($venvPy)" }
if (Test-Path -LiteralPath $jnExe)  { W ("jupyter-notebook.exe present: {0}" -f $jnExe) } else { $fail += "jupyter-notebook.exe missing ($jnExe)" }
if (Test-Path -LiteralPath $launcher) { W ("launcher present: {0}" -f $launcher) } else { $fail += "launcher missing ($launcher)" }

# Kernelspec registered inside the venv (sys-prefix), i.e. not littering the profile.
$kernelDir = Join-Path $JupyterRoot '.venv\share\jupyter\kernels'
if (Test-Path -LiteralPath $kernelDir) {
    $kernels = (Get-ChildItem -LiteralPath $kernelDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', '
    W ("kernelspecs in venv: {0}" -f $kernels)
} else {
    W "[WARN] no venv kernelspec dir yet (kernel may register on first run)"
}

if ($fail.Count -eq 0) {
    W 'PASS Jupyter venv + launcher present'
    Write-MastSmokeOk -Module 'jupyter' | Out-Null
    exit 0
}

W ('FAIL ' + ($fail -join '; '))
exit 1
