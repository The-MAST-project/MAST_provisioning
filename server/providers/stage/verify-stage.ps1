#requires -Version 5.1
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts predate it and probe optional properties
${verifyLog} = Get-MastVerifyLog -Module 'stage'

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
    Write-MastSmokeOk -Module 'stage' | Out-Null
    exit 0
} else {
    exit 1
}
