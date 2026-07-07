#requires -Version 5.1
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off

${verifyLog} = Get-MastVerifyLog -Module 'intel-nic-driver'
${smokeFile} = Get-MastSmokeMarker -Module 'intel-nic-driver'

function Write-VLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${verifyLog} -Encoding UTF8 `
    -Value ("[{0}] verify-intel-nic-driver.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# The Intel I225-V driver is STAGED in the driver store (pnputil /add-driver).
# That is OS- and hardware-independent, so this verify works on the dev VM (no
# I225 present) as well as a real unit. Functional binding -- the live NIC
# actually running 1.1.4.45 -- only happens once the I225 hardware enumerates the
# staged package, and must be confirmed on real unit hardware.
${enum} = (& pnputil.exe /enum-drivers 2>&1) -join "`n"
${staged} = (${enum} -match 'e2f\.inf')
Write-VLog ("e2f.inf present in driver store: {0}" -f ${staged})

if (-not ${staged}) {
    Write-VLog 'FAIL: e2f.inf not present in driver store (pnputil /enum-drivers)'
    exit 1
}

# Log the staged version line for the record (best effort).
${verLine} = (${enum} -split "`r?`n") | Select-String -Pattern 'e2f\.inf' -Context 0,4 | Select-Object -First 1
if (${verLine}) { Write-VLog ("store entry: {0}" -f (${verLine}.ToString() -replace "`r?`n", ' | ')) }

Set-Content -LiteralPath ${smokeFile} -Encoding UTF8 -Value 'intel_nic_driver_ok'
Write-VLog 'PASS: Intel I225-V driver staged in the driver store'
exit 0
