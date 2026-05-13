#requires -Version 5.1
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${logRoot} = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'logs'
${verifyLog} = Join-Path ${logRoot} 'verify\stage-verify.log'
${smokeFile} = Join-Path ${logRoot} 'smoke\stage-smoke.txt'

${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${verifyLog}) -ErrorAction SilentlyContinue

${lines} = @()
${ok} = $true

# Check XILab.exe
${candidates} = @(
    'C:\Program Files\XILab\XILab.exe',
    'C:\Program Files (x86)\XILab\XILab.exe'
)
${found} = $null
foreach (${c} in ${candidates}) {
    if (Test-Path -LiteralPath ${c}) { ${found} = ${c}; break }
}
if (${found}) {
    ${lines} += ("Stage (XILab) OK: {0}" -f ${found})
} else {
    ${lines} += ("[FAIL] xilab.exe not found (checked: {0})" -f (${candidates} -join '; '))
    ${ok} = $false
}

# Check driver in PnPUtil driver store
${pnpOut} = & pnputil.exe /enum-drivers 2>&1
${driverFound} = ($pnpOut | Select-String 'standa_8smc4-5\.inf' -Quiet)
if (${driverFound}) {
    ${lines} += 'Driver OK: standa_8smc4-5.inf present in driver store'
} else {
    ${lines} += '[FAIL] standa_8smc4-5.inf not found in driver store (pnputil /enum-drivers)'
    ${ok} = $false
}

${lines} | Out-File -FilePath ${verifyLog} -Encoding UTF8
if (${ok}) {
    Set-Content -Path ${smokeFile} -Value 'stage_ok' -Encoding UTF8
    exit 0
} else {
    exit 1
}
