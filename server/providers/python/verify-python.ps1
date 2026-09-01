#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\Python312'
)

# Verify Python: the interpreter reports a version, pip is available, virtualenv is
# absent, and -- the check the others exist for -- a venv can actually be created.
# The venv assertion creates a throwaway one under $env:TEMP, confirms it yields a
# Scripts\python.exe and removes it again, because that is exactly what
# provide-jupyter.ps1 does with C:\MAST\jupyter\.venv. "python -m venv --help
# exits 0" is a weaker statement than "a venv comes out", and jupyter consumes the
# stronger one.
#
# Replaces the inline one-liner that was in module.json's "verify" key; same log
# and smoke-marker paths. A one-liner cannot express a failure, which is why this
# is a script (#131).
$ErrorActionPreference = 'Stop'

$mastLogDot = Join-Path $PSScriptRoot 'mast-log.ps1'
if (-not (Test-Path $mastLogDot)) { $mastLogDot = Join-Path $PSScriptRoot '..\..\lib\mast-log.ps1' }
. $mastLogDot
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts probe optional properties

$verifyLog = Get-MastVerifyLog -Module 'python'
function W { param([string]$Line) Add-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Line) }
Set-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] verify-python.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

function Invoke-Probe {
    # Run a native probe and return its exit code and merged output.
    #
    # $ErrorActionPreference is forced to Continue for the call: under 'Stop',
    # Windows PowerShell 5.1 raises NativeCommandError as soon as a native command
    # writes to stderr, and `*>$null` does not prevent it. `pip show <absent
    # package>` writes "WARNING: Package(s) not found" to stderr and exits 1 --
    # a normal answer here, and the one this script exists to get. Measured on the
    # dev VM: with 'Stop' in force the script died on that call, so it could only
    # ever have passed on a unit that still had virtualenv.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$NativeArgs
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @NativeArgs 2>&1
        return [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($out | Out-String).Trim() }
    }
    finally { $ErrorActionPreference = $prev }
}

$fail = @()
$facts = @{}

$pythonExe = Join-Path $InstallDir 'python.exe'
if (-not (Test-Path -LiteralPath $pythonExe)) {
    W ("FAIL python.exe not found at {0}" -f $pythonExe)
    exit 1
}

# --- the interpreter, and what the fleet report carries about it ---
$version = Invoke-Probe -Exe $pythonExe -NativeArgs @('--version')
if ($version.Code -eq 0 -and $version.Output) {
    W ("python: {0} ({1})" -f $version.Output, $pythonExe)
    $facts['python_version'] = $version.Output
} else {
    $fail += ("python.exe present but reported no version (exit {0}): {1}" -f $version.Code, $version.Output)
}

# --- pip: provide-jupyter installs its locked wheelhouse with it (--no-index) ---
$pip = Invoke-Probe -Exe $pythonExe -NativeArgs @('-m', 'pip', '--version')
if ($pip.Code -eq 0) {
    W 'pip: available'
} else {
    $fail += ("pip is not available (python -m pip --version exit {0})" -f $pip.Code)
}

# --- virtualenv must be gone, not merely unused (#131) ---
$virtualenv = Invoke-Probe -Exe $pythonExe -NativeArgs @('-m', 'pip', 'show', 'virtualenv')
if ($virtualenv.Code -eq 0) {
    $fail += 'virtualenv is installed; provide-python removes it and nothing should put it back'
} else {
    W 'virtualenv: absent'
}

# --- the capability itself: a venv that yields an interpreter ---
$probe = Join-Path $env:TEMP ('mast-venv-probe-' + [guid]::NewGuid().ToString('N'))
try {
    $made = Invoke-Probe -Exe $pythonExe -NativeArgs @('-m', 'venv', $probe)
    $probePy = Join-Path $probe 'Scripts\python.exe'
    if ($made.Code -eq 0 -and (Test-Path -LiteralPath $probePy)) {
        W ("venv: created {0} and it yielded an interpreter" -f $probe)
    } else {
        $fail += ("python -m venv produced no interpreter (exit {0}, {1} {2}): {3}" -f $made.Code, $probePy, $(if (Test-Path -LiteralPath $probePy) { 'present' } else { 'missing' }), $made.Output)
    }
}
finally {
    Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
}

# Hand the observations to execute, which folds them into the module's entry in
# installed-manifest.json, so the fleet report can answer "which Python is on each
# unit" without visiting them. Written whether or not the checks passed.
try { $null = Write-MastModuleFacts -Module 'python' -Facts $facts }
catch { W ("[WARN] could not record module facts: {0}" -f $_.Exception.Message) }

if ($fail.Count -eq 0) {
    W 'PASS python + pip + stdlib venv, virtualenv absent'
    Write-MastSmokeOk -Module 'python' | Out-Null
    exit 0
}

W ('FAIL ' + ($fail -join '; '))
exit 1
