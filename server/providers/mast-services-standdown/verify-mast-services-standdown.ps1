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

${supervisorService} = Get-MastSupervisorServiceName
${supervisor} = Get-Service -Name (Get-MastSupervisorServiceName) -ErrorAction SilentlyContinue
if (($null -ne ${supervisor}) -and (${supervisor}.Status -ne 'Stopped')) {
    ("mast-services-standdown FAIL: {0} is {1}, expected Stopped for the run" -f ${supervisorService}, ${supervisor}.Status) |
        Out-File -FilePath ${verifyLog} -Encoding UTF8
    exit 1
}

("mast-services-standdown OK: no legacy MAST service is registered, and {0} is not running" -f ${supervisorService}) |
    Out-File -FilePath ${verifyLog} -Encoding UTF8
Write-MastSmokeOk -Module 'mast-services-standdown' | Out-Null
exit 0
