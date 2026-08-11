#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('RemoteSigned', 'AllSigned', 'Restricted', 'Unrestricted', 'Bypass')]
    [string]${Policy} = 'RemoteSigned'
)

# Verify the machine-wide ExecutionPolicy, live -- not from the smoke marker alone.
#
# The marker says what the last provide RECORDED; this reads what the machine says
# NOW. Those differ exactly in the case this provider exists for: someone (or a new
# GPO) changed the policy out of band after a clean run. Since drift detection is
# payload-hash-based, nothing else on the unit would notice. See #51.
#
# Checks LocalMachine AND the GPO scopes, because Set-ExecutionPolicy succeeds
# silently when a MachinePolicy/UserPolicy scope outranks it: the persisted value can
# read correct while the effective policy is still Restricted. Asserting only the
# scope we write would report a unit healthy that still cannot run a bare
# `powershell -File`.

${ErrorActionPreference} = 'Stop'

${logRoot}   = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'logs'
${verifyLog} = Join-Path ${logRoot} 'verify\execution-policy-verify.log'
${smokeFile} = Join-Path ${logRoot} 'smoke\execution-policy-smoke.txt'
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${verifyLog}) -ErrorAction SilentlyContinue

function Write-EpLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

${failed} = $false

if (-not (Test-Path -LiteralPath ${smokeFile})) {
    Write-EpLog 'FAIL: execution-policy smoke marker missing (provide did not complete).'
    ${failed} = $true
}
else {
    ${body} = (Get-Content -LiteralPath ${smokeFile} -Raw).Trim()
    if (${body} -match '^execution-policy_ok') {
        Write-EpLog ("smoke marker: {0}" -f ${body})
    }
    else {
        Write-EpLog ("FAIL: unexpected execution-policy smoke body: {0}" -f ${body})
        ${failed} = $true
    }
}

# The live check, which is the point of this verify.
${lm} = (Get-ExecutionPolicy -Scope LocalMachine).ToString()
if (${lm} -eq ${Policy}) {
    Write-EpLog ("LocalMachine = {0} as provisioned." -f ${lm})
}
else {
    Write-EpLog ("FAIL: LocalMachine = {0}, expected {1}. Changed out of band since the last run -- " -f ${lm}, ${Policy})
    Write-EpLog ('a payload-hash drift check cannot see this, which is why it is asserted here.')
    ${failed} = $true
}

# A defined GPO scope outranks whatever LocalMachine holds.
foreach (${row} in (Get-ExecutionPolicy -List)) {
    Write-EpLog ("  scope: {0} = {1}" -f ${row}.Scope, ${row}.ExecutionPolicy)
}
${gpo} = @(Get-ExecutionPolicy -List |
    Where-Object { $_.Scope -in @('MachinePolicy', 'UserPolicy') -and $_.ExecutionPolicy -ne 'Undefined' })
if (${gpo}.Count -gt 0) {
    ${which} = (${gpo} | ForEach-Object { "{0}={1}" -f $_.Scope, $_.ExecutionPolicy }) -join ', '
    Write-EpLog ("FAIL: Group Policy defines {0}, which outranks LocalMachine = {1}. " -f ${which}, ${lm})
    Write-EpLog ('The persisted value is irrelevant while a GPO scope is set; this needs a domain-policy change.')
    ${failed} = $true
}

if (${failed}) { exit 1 }

Write-EpLog ("OK: execution policy verified (LocalMachine = {0}, no GPO override)." -f ${lm})
exit 0
