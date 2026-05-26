#requires -Version 5.1
[CmdletBinding()]
param(
    [string]${ReposRoot}     = 'C:\MAST\repos',
    [string]${SmokeFitsPath} = 'C:\MAST\full-frame.fits',
    [int]   ${TimeoutSeconds} = 300
)

${ErrorActionPreference} = 'Stop'

${logRoot}   = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'logs'
${runLog}    = Join-Path ${logRoot} 'verify\mast-validation-install.log'
${smokeFile} = Join-Path ${logRoot} 'smoke\mast-validation-smoke.txt'
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${runLog})    -ErrorAction SilentlyContinue
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${smokeFile}) -ErrorAction SilentlyContinue

function Write-VLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${runLog} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${runLog} -Encoding UTF8 `
    -Value ("[{0}] provide-mast-validation.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# Locate the MAST_unit clone. Repo names from mast-repos.txt may vary
# (MAST_unit.2024-12-12, MAST_unit, etc.) so we resolve by prefix.
${unitDir} = $null
if (Test-Path -LiteralPath ${ReposRoot}) {
    ${match} = Get-ChildItem -LiteralPath ${ReposRoot} -Directory -ErrorAction SilentlyContinue `
        | Where-Object { ${_}.Name -like 'MAST_unit*' } `
        | Select-Object -First 1
    if (${match}) { ${unitDir} = ${match}.FullName }
}
if (-not ${unitDir}) {
    Write-VLog ("FAIL: no MAST_unit* clone under {0}" -f ${ReposRoot})
    exit 1
}
Write-VLog ("MAST_unit clone: {0}" -f ${unitDir})

${venvPython} = Join-Path ${unitDir} '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath ${venvPython})) {
    Write-VLog ("FAIL: venv python missing at {0}" -f ${venvPython})
    exit 1
}
Write-VLog ("venv python:     {0}" -f ${venvPython})

${unitSrc} = Join-Path ${unitDir} 'src'
if (-not (Test-Path -LiteralPath ${unitSrc})) {
    Write-VLog ("FAIL: MAST_unit src dir not found at {0}" -f ${unitSrc})
    exit 1
}

# Locate the validation script next to this provider (and in staging it sits in
# the same folder). The script is run with the venv python, with MAST_unit's
# src/ injected as the first sys.path entry.
${validatePy} = Join-Path ${PSScriptRoot} 'validate_mastrometry.py'
if (-not (Test-Path -LiteralPath ${validatePy})) {
    Write-VLog ("FAIL: validate_mastrometry.py not found next to provider at {0}" -f ${validatePy})
    exit 1
}

# Cygwin lapack dir must be on PATH for any solve-field invocation that may
# fork removelines/uniformize -> numpy._umath_linalg. Match what
# provide-astrometry-dependencies.ps1 prepends to machine PATH. Re-prepending
# here is idempotent (the machine value already covers it after a reboot, but
# this provider may run in the same session as the install).
${env:PATH} = 'C:\cygwin64\bin' + ';' + ${env:PATH}

${stdoutLog} = Join-Path ${logRoot} 'verify\mast-validation.stdout.log'
${stderrLog} = Join-Path ${logRoot} 'verify\mast-validation.stderr.log'
Remove-Item -LiteralPath ${stdoutLog}, ${stderrLog} -Force -ErrorAction SilentlyContinue

# Pass MAST_PROJECT=unit so any Config touch resolves the unit profile.
${env:MAST_PROJECT} = 'unit'

${argList} = @(
    ${validatePy},
    '--unit-src',    ${unitSrc},
    '--fits',        ${SmokeFitsPath},
    '--smoke-file',  ${smokeFile}
)
Write-VLog ("Invoking: {0} {1}" -f ${venvPython}, (${argList} -join ' '))

${proc} = Start-Process -FilePath ${venvPython} -ArgumentList ${argList} `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput ${stdoutLog} -RedirectStandardError ${stderrLog}

${finished} = ${proc}.WaitForExit(${TimeoutSeconds} * 1000)
if (-not ${finished}) {
    try { ${proc}.Kill() } catch {}
    Write-VLog ("FAIL: validator timed out after {0}s" -f ${TimeoutSeconds})
    exit 1
}
try { ${proc}.Refresh() } catch {}
${rc} = ${proc}.ExitCode
if ($null -eq ${rc}) {
    Write-VLog "FAIL: validator exit code was null"
    exit 1
}

Write-VLog ("validator exit={0}" -f ${rc})
if (Test-Path -LiteralPath ${stdoutLog}) {
    Write-VLog "--- validator stdout tail ---"
    Get-Content -LiteralPath ${stdoutLog} -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object { Write-VLog ${_} }
}
if ((${rc} -ne 0) -and (Test-Path -LiteralPath ${stderrLog})) {
    Write-VLog "--- validator stderr tail ---"
    Get-Content -LiteralPath ${stderrLog} -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object { Write-VLog ${_} }
}

if (${rc} -ne 0) {
    Write-VLog "FAIL: MAST_unit-driven plate solve validation did not succeed."
    exit 1
}

# Sanity: the Python validator writes the smoke marker itself. Confirm it
# made it to disk before claiming success.
if (-not (Test-Path -LiteralPath ${smokeFile})) {
    Write-VLog ("FAIL: validator exited 0 but smoke marker missing at {0}" -f ${smokeFile})
    exit 1
}
Write-VLog ("PASS: smoke marker present at {0}" -f ${smokeFile})
exit 0
