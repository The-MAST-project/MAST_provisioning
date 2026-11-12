#requires -Version 5.1
[CmdletBinding()]
param(
    # The unit's registry 'supervised' flag, injected by build-mast.ps1.
    [switch]${Supervised}
)

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; we probe optional properties

${namesDot} = Join-Path ${PSScriptRoot} 'mast-service-names.ps1'
if (-not (Test-Path ${namesDot})) { throw "mast-service-names.ps1 not found beside verify script." }
. ${namesDot}

${verifyLog} = Get-MastVerifyLog -Module 'mast-services-finalize'
${issues} = New-Object 'System.Collections.Generic.List[string]'

${remaining} = Get-MastRegisteredServiceNames
if (${remaining}.Count -gt 0) {
    [void]${issues}.Add(("still registered at end of run: {0}" -f (${remaining} -join ', ')))
}

${supervisorService} = Get-MastSupervisorServiceName
${supervisor} = Get-Service -Name (Get-MastSupervisorServiceName) -ErrorAction SilentlyContinue
if (${Supervised}) {
    if ($null -eq ${supervisor}) {
        [void]${issues}.Add(("{0} is not registered on a supervised unit" -f ${supervisorService}))
    }
    elseif (${supervisor}.Status -ne 'Running') {
        [void]${issues}.Add(("{0} is {1}, expected Running" -f ${supervisorService}, ${supervisor}.Status))
    }
}
elseif ($null -ne ${supervisor}) {
    [void]${issues}.Add(("{0} is registered on a unit that is not supervised" -f ${supervisorService}))
}

if (${issues}.Count -gt 0) {
    ("mast-services-finalize FAIL: " + (${issues} -join '; ')) | Out-File -FilePath ${verifyLog} -Encoding UTF8
    exit 1
}

${state} = if (${Supervised}) { ("{0} running" -f ${supervisorService}) } else { ("{0} absent" -f ${supervisorService}) }
("mast-services-finalize OK: no legacy MAST service is registered; {0}" -f ${state}) | Out-File -FilePath ${verifyLog} -Encoding UTF8
Write-MastSmokeOk -Module 'mast-services-finalize' | Out-Null
exit 0
