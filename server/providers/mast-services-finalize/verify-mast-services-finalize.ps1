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

${verifyLog} = Get-MastVerifyLog -Module 'mast-services-finalize'
${issues} = New-Object 'System.Collections.Generic.List[string]'
${lines}  = New-Object 'System.Collections.Generic.List[string]'

foreach (${svcName} in (Get-MastServiceNames)) {
    ${svc} = Get-Service -Name ${svcName} -ErrorAction SilentlyContinue
    if ($null -eq ${svc}) {
        [void]${lines}.Add(("SKIP {0}: not registered" -f ${svcName}))
        continue
    }
    ${startMode} = (Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f ${svcName}) -ErrorAction SilentlyContinue).StartMode
    if (${startMode} -ne 'Manual') {
        [void]${issues}.Add(("{0}: StartMode='{1}' (expected Manual)" -f ${svcName}, ${startMode}))
    }
    if (${svc}.Status -ne 'Stopped') {
        [void]${issues}.Add(("{0}: Status='{1}' (expected Stopped)" -f ${svcName}, ${svc}.Status))
    }
    [void]${lines}.Add(("{0}: StartMode={1} Status={2}" -f ${svcName}, ${startMode}, ${svc}.Status))
}

if (${issues}.Count -gt 0) {
    (("mast-services-finalize FAIL: " + (${issues} -join '; ')) + "`r`n" + (${lines} -join "`r`n")) |
        Out-File -FilePath ${verifyLog} -Encoding UTF8
    exit 1
}

(("mast-services-finalize OK") + "`r`n" + (${lines} -join "`r`n")) | Out-File -FilePath ${verifyLog} -Encoding UTF8
Write-MastSmokeOk -Module 'mast-services-finalize' | Out-Null
exit 0
