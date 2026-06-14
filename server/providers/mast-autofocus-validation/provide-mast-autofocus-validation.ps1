#requires -Version 5.1
[CmdletBinding()]
param(
    [string]${ReposRoot}              = 'C:\MAST\repos',
    [int]   ${Port}                   = 8998,
    [int]   ${PerSeriesTimeoutSeconds} = 90
)

# End-to-end autofocus solve validation. Mirrors provide-mast-validation.ps1:
# locate the MAST_unit clone + its venv, run a validation script through the
# unit's production code paths, and drop a smoke marker the verify step checks.
#
# The validator (validate_autofocus_solve.py, shipped beside this script) drives
# focus_analysis.analyze_focus_files against the FITS focus sweeps bundled in
# autofocus-fits.zip (this provider's git-lfs asset), to confirm ps3cli --server
# can fit a v-curve and return an autofocus solution. No --allow-missing-avx
# escape is needed: unlike astrometry-engine, ps3cli focus analysis runs on the
# AVX-less dev VM CPU.

${ErrorActionPreference} = 'Stop'

${logRoot}   = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'logs'
${runLog}    = Join-Path ${logRoot} 'verify\mast-autofocus-validation-install.log'
${stdoutLog} = Join-Path ${logRoot} 'verify\mast-autofocus-validation.stdout.log'
${smokeFile} = Join-Path ${logRoot} 'smoke\mast-autofocus-validation-smoke.txt'
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${runLog})    -ErrorAction SilentlyContinue
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${smokeFile}) -ErrorAction SilentlyContinue

function Write-VLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${runLog} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${runLog} -Encoding UTF8 `
    -Value ("[{0}] provide-mast-autofocus-validation.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# --- Locate the MAST_unit clone (name may carry a date suffix) -------------
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

${unitSrc} = Join-Path ${unitDir} 'src'
if (-not (Test-Path -LiteralPath ${unitSrc})) {
    Write-VLog ("FAIL: MAST_unit src not found at {0}" -f ${unitSrc})
    exit 1
}
${venvPython} = Join-Path ${unitDir} '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath ${venvPython})) {
    Write-VLog ("FAIL: venv python missing at {0}" -f ${venvPython})
    exit 1
}

${harness} = Join-Path ${PSScriptRoot} 'validate_autofocus_solve.py'
if (-not (Test-Path -LiteralPath ${harness})) {
    Write-VLog ("FAIL: validate_autofocus_solve.py not found beside provider at {0}" -f ${harness})
    exit 1
}

# --- Locate + extract the FITS bundle --------------------------------------
# In staging the build flattens assets/ to the script's folder; in the repo it
# sits under assets/. The .zip is git-lfs tracked, so an unpulled pointer is a
# tiny text stub -- guard on size before trusting it.
${zip} = Join-Path ${PSScriptRoot} 'autofocus-fits.zip'
if (-not (Test-Path -LiteralPath ${zip})) {
    ${zip} = Join-Path ${PSScriptRoot} 'assets\autofocus-fits.zip'
}
if (-not (Test-Path -LiteralPath ${zip})) {
    Write-VLog ("FAIL: autofocus-fits.zip not found beside provider ({0})" -f ${PSScriptRoot})
    exit 1
}
${zipItem} = Get-Item -LiteralPath ${zip}
if (${zipItem}.Length -lt 1MB) {
    Write-VLog ("FAIL: autofocus-fits.zip is {0} bytes -- looks like an unresolved git-lfs pointer. Ensure git-lfs is installed and the provisioning checkout ran 'git lfs pull'." -f ${zipItem}.Length)
    exit 1
}

${fitsDir} = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'autofocus-fits'
if (Test-Path -LiteralPath ${fitsDir}) { Remove-Item -LiteralPath ${fitsDir} -Recurse -Force -ErrorAction SilentlyContinue }
${null} = New-Item -ItemType Directory -Force -Path ${fitsDir}
Write-VLog ("extracting {0} -> {1}" -f ${zipItem}.FullName, ${fitsDir})
Expand-Archive -LiteralPath ${zipItem}.FullName -DestinationPath ${fitsDir} -Force

${expected} = Join-Path ${fitsDir} 'expected.json'
${sampleFits} = Get-ChildItem -LiteralPath ${fitsDir} -Recurse -Filter '*.fits' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not ${sampleFits}) {
    Write-VLog ("FAIL: no FITS extracted under {0}" -f ${fitsDir})
    exit 1
}
Write-VLog ("FITS OK: sample {0} is {1:N0} bytes" -f ${sampleFits}.Name, ${sampleFits}.Length)

# --- Run the harness against the unit's venv -------------------------------
# Use the already-running ps3cli --server (started by the mast-unit service via
# app.py) if port is open; otherwise have the harness start a throwaway server.
${portOpen} = $false
try {
    ${portOpen} = (Test-NetConnection -ComputerName '127.0.0.1' -Port ${Port} -WarningAction SilentlyContinue).TcpTestSucceeded
} catch { ${portOpen} = $false }
Write-VLog ("ps3cli port {0} open: {1}" -f ${Port}, ${portOpen})

${argList} = @(
    ${harness},
    '--unit-src', ${unitSrc},
    '--fits-dir', ${fitsDir},
    '--expected', ${expected},
    '--port',     ${Port},
    '--timeout',  ${PerSeriesTimeoutSeconds}
)
if (-not ${portOpen}) {
    ${argList} += '--start-server'
    Write-VLog "no server detected; harness will start a throwaway ps3cli --server"
} else {
    Write-VLog "using the already-running ps3cli --server"
}

Remove-Item -LiteralPath ${stdoutLog} -Force -ErrorAction SilentlyContinue
Write-VLog ("Invoking: {0} {1}" -f ${venvPython}, (${argList} -join ' '))

# Direct & invocation (not Start-Process) so $LASTEXITCODE is reliable -- same
# rationale as provide-mast-validation.ps1.
${rc} = $null
try {
    & ${venvPython} @argList 2>&1 | Tee-Object -FilePath ${stdoutLog} -Append | Out-Host
    ${rc} = $LASTEXITCODE
} catch {
    Write-VLog ("FAIL: invoker threw: {0}" -f $_.Exception.Message)
    exit 1
}

Write-VLog ("harness exit={0}" -f ${rc})
if (Test-Path -LiteralPath ${stdoutLog}) {
    Write-VLog "--- harness output tail ---"
    Get-Content -LiteralPath ${stdoutLog} -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object { Write-VLog ${_} }
}

if ($null -eq ${rc} -or ${rc} -ne 0) {
    Write-VLog "FAIL: autofocus solve validation did not pass."
    exit 1
}

Set-Content -LiteralPath ${smokeFile} -Value 'mast-autofocus-validation_ok' -Encoding ASCII
Write-VLog ("PASS: smoke marker written at {0}" -f ${smokeFile})
exit 0
