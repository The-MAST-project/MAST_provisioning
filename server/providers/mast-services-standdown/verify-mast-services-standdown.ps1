#requires -Version 5.1
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; we probe optional properties

${namesDot} = Join-Path ${PSScriptRoot} 'mast-service-names.ps1'
if (-not (Test-Path ${namesDot})) { throw "mast-service-names.ps1 not found beside verify script." }
. ${namesDot}

${verifyLog} = Get-MastVerifyLog -Module 'mast-services-standdown'
${remaining} = Get-MastRegisteredServiceNames

if (${remaining}.Count -gt 0) {
    ("mast-services-standdown FAIL: still registered: " + (${remaining} -join ', ')) |
        Out-File -FilePath ${verifyLog} -Encoding UTF8
    exit 1
}

"mast-services-standdown OK: no MAST service is registered" | Out-File -FilePath ${verifyLog} -Encoding UTF8
Write-MastSmokeOk -Module 'mast-services-standdown' | Out-Null
exit 0
