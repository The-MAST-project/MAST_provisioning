#requires -Version 5.1
[CmdletBinding()]
param(
    [string]${ReposRoot}     = 'C:\MAST\repos',
    [string]${SmokeFitsPath} = 'C:\MAST\full-frame.fits',
    [int]   ${TimeoutSeconds} = 300,
    # Dev-VM-only escape: forwards --allow-missing-avx to the python validator
    # so a SIGILL crash (guest CPU lacks AVX/AVX2/FMA) is treated as SKIPPED
    # instead of FAIL. build-mast.ps1 injects this only under -TestMode; MUST
    # NOT be passed in production. Corrupt index files remain a hard FAIL.
    [switch]${AllowMissingAvx}
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
Remove-Item -LiteralPath ${stdoutLog} -Force -ErrorAction SilentlyContinue

# Pass MAST_PROJECT=unit so any Config touch resolves the unit profile.
${env:MAST_PROJECT} = 'unit'

${argList} = @(
    ${validatePy},
    '--unit-src',    ${unitSrc},
    '--fits',        ${SmokeFitsPath},
    '--smoke-file',  ${smokeFile}
)
if (${AllowMissingAvx}) { ${argList} += '--allow-missing-avx' }
Write-VLog ("Invoking: {0} {1}" -f ${venvPython}, (${argList} -join ' '))

# Direct invocation (not Start-Process). Run #9 hit a PS 5.1 race where
# Start-Process -PassThru + WaitForExit(ms) returned $true but the handle
# disposed before .ExitCode could be read -- we got $null and wrongly
# threw, even though the validator had exited 0 and written its smoke
# marker. Direct & invocation makes $LASTEXITCODE reliable, and merging
# stderr via 2>&1 keeps everything in one stream.
${rc} = $null
try {
    & ${venvPython} @argList 2>&1 | Tee-Object -FilePath ${stdoutLog} -Append | Out-Host
    ${rc} = $LASTEXITCODE
} catch {
    Write-VLog ("FAIL: invoker threw: {0}" -f $_.Exception.Message)
    exit 1
}

Write-VLog ("validator exit={0}" -f ${rc})
if (Test-Path -LiteralPath ${stdoutLog}) {
    Write-VLog "--- validator output tail ---"
    Get-Content -LiteralPath ${stdoutLog} -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object { Write-VLog ${_} }
}

# If $LASTEXITCODE is null (rare; should not happen with & invocation but
# guard anyway), fall back to inspecting the smoke marker the Python side
# always writes -- if the marker has a recognizable body, the validator
# completed even if we lost the exit code.
if ($null -eq ${rc}) {
    if ((Test-Path -LiteralPath ${smokeFile}) -and `
        ((Get-Content -LiteralPath ${smokeFile} -Raw -ErrorAction SilentlyContinue) -match '^mastrometry_ok ')) {
        Write-VLog ("INFO: \$LASTEXITCODE was null but smoke marker present -- treating as success.")
        ${rc} = 0
    } else {
        Write-VLog "FAIL: validator exit code null and no smoke marker; cannot determine outcome."
        exit 1
    }
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
