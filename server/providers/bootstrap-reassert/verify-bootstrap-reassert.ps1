#requires -Version 5.1
<#
.SYNOPSIS
  Confirm the re-assert ran this cycle and applied every element it selected.

.NOTES
  Reads the 'reassert' block provide- wrote into C:\MAST\bootstrap-manifest.json
  and turns it into module facts, so tools\fleet-drift-report.py sees per-unit
  re-assert state without a second gatherer.

  It deliberately does NOT check bootstrap_version. A re-assert applies the
  routine elements and by construction not the console ones, so the unit is not
  at the current bootstrap version afterwards and must not be reported as if it
  were -- see the decision record named in module.json.
#>
[CmdletBinding()]
param(
    # A stale block from an earlier cycle must not be read as this run's result.
    [int]${MaxAgeHours} = 24
)

${ErrorActionPreference} = 'Stop'

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; this probes optional properties

${verifyLog} = Get-MastVerifyLog -Module 'bootstrap-reassert'
${smokeFile} = Get-MastSmokeMarker -Module 'bootstrap-reassert'

function Write-VLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${verifyLog} -Encoding UTF8 `
    -Value ("[{0}] verify-bootstrap-reassert.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

${fail} = @()
${facts} = @{ reassert_state = 'unknown' }

if (-not (Test-Path -LiteralPath ${smokeFile})) {
    Write-VLog ("FAIL: smoke marker missing at {0}" -f ${smokeFile})
    exit 1
}

${manifestPath} = Join-Path ${env:SystemDrive} 'MAST\bootstrap-manifest.json'
if (-not (Test-Path -LiteralPath ${manifestPath})) {
    ${fail} += 'bootstrap-manifest.json is missing; the re-assert recorded nothing'
}
else {
    try {
        ${doc} = Get-Content -LiteralPath ${manifestPath} -Raw | ConvertFrom-Json
    } catch {
        ${doc} = $null
        ${fail} += ("bootstrap-manifest.json is unreadable: {0}" -f $_.Exception.Message)
    }

    ${block} = if (${doc}) { ${doc}.reassert } else { $null }
    if ($null -eq ${block}) {
        ${fail} += 'no reassert block in bootstrap-manifest.json'
    }
    else {
        ${applied} = @(${block}.applied)
        ${failed} = @(${block}.failed)
        ${at} = [string]${block}.at

        Write-VLog ("reassert at={0} script_version={1} applied={2} failed={3}" -f `
            ${at}, ${block}.script_version, ${applied}.Count, ${failed}.Count)
        foreach (${a} in ${applied}) { Write-VLog ("  [OK]   {0}" -f ${a}) }
        foreach (${f} in ${failed}) { Write-VLog ("  [FAIL] {0}" -f ${f}) }

        ${ageOk} = $false
        try {
            ${ts} = [datetime]::Parse(${at}, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
            ${ageHours} = ((Get-Date).ToUniversalTime() - ${ts}).TotalHours
            ${ageOk} = (${ageHours} -le ${MaxAgeHours})
            if (-not ${ageOk}) {
                ${fail} += ("the reassert block is {0:N1} h old (> {1} h); this cycle did not record one" -f ${ageHours}, ${MaxAgeHours})
            }
        } catch {
            ${fail} += ("could not read the reassert timestamp '{0}'" -f ${at})
        }

        if (${failed}.Count -gt 0) {
            ${fail} += ("element(s) failed to re-assert: {0}" -f (${failed} -join ', '))
        }

        ${facts} = @{
            reassert_state          = $(if (${failed}.Count -gt 0) { 'failed' } elseif (${ageOk}) { 'applied' } else { 'stale' })
            reassert_at             = ${at}
            reassert_applied_count  = ${applied}.Count
            reassert_applied        = ((${applied} | Sort-Object) -join ',')
            reassert_failed         = ((${failed} | Sort-Object) -join ',')
            reassert_script_version = [string]${block}.script_version
            # Recorded, never asserted: a re-assert does not advance it, and the
            # drift report needs it to keep naming what console work is missing.
            bootstrap_version       = [string]${doc}.bootstrap_version
        }
    }
}

try { ${null} = Write-MastModuleFacts -Module 'bootstrap-reassert' -Facts ${facts} }
catch { Write-VLog ("WARNING: could not write bootstrap-reassert facts: {0}" -f $_.Exception.Message) }

if (${fail}.Count -eq 0) {
    Set-Content -LiteralPath ${smokeFile} -Encoding UTF8 -Value 'bootstrap_reassert_ok'
    Write-VLog 'PASS: the re-assertable bootstrap elements were applied this cycle'
    exit 0
}
else {
    Write-VLog ('FAIL: ' + (${fail} -join '; '))
    exit 1
}
