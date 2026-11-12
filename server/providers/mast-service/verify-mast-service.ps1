#requires -Version 5.1
[CmdletBinding()]
param(
    [string]${Top} = 'C:\MAST\src',

    # The unit's registry 'supervised' flag, injected by build-mast.ps1.
    [switch]${Supervised}
)

# The registration, not the running state: this provider never starts the service,
# and standdown has stopped it for the run. Finalize's verify asserts it is running.

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; we probe optional properties

${namesDot} = Join-Path ${PSScriptRoot} 'mast-service-names.ps1'
if (-not (Test-Path ${namesDot})) { throw "mast-service-names.ps1 not found beside verify script." }
. ${namesDot}

${LOCAL_SYSTEM}   = 'LocalSystem'
${AUTO_START}     = 'Auto'
${SERVICE_MODULE} = 'supervision.service'

${serviceName} = Get-MastSupervisorServiceName
${verifyLog}   = Get-MastVerifyLog -Module 'mast-service'
${service}     = Get-Service -Name (Get-MastSupervisorServiceName) -ErrorAction SilentlyContinue

if (-not ${Supervised}) {
    if ($null -ne ${service}) {
        ("mast-service FAIL: {0} is registered on a unit that is not supervised" -f ${serviceName}) |
            Out-File -FilePath ${verifyLog} -Encoding UTF8
        exit 1
    }
    ("mast-service OK: {0} absent (unit not supervised)" -f ${serviceName}) | Out-File -FilePath ${verifyLog} -Encoding UTF8
    Write-MastSmokeOk -Module 'mast-service' | Out-Null
    exit 0
}

${issues} = New-Object 'System.Collections.Generic.List[string]'
if ($null -eq ${service}) {
    [void]${issues}.Add(("{0} is not registered" -f ${serviceName}))
}
else {
    ${cim} = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f ${serviceName})
    if (-not (Test-MastNssmService -Name ${serviceName})) { [void]${issues}.Add(("not nssm-hosted: {0}" -f ${cim}.PathName)) }
    if (${cim}.StartName -ne ${LOCAL_SYSTEM}) { [void]${issues}.Add(("runs as {0}, expected {1}" -f ${cim}.StartName, ${LOCAL_SYSTEM})) }
    if (${cim}.StartMode -ne ${AUTO_START}) { [void]${issues}.Add(("start mode {0}, expected {1}" -f ${cim}.StartMode, ${AUTO_START})) }

    ${parameters} = Get-ItemProperty -Path ("HKLM:\SYSTEM\CurrentControlSet\Services\{0}\Parameters" -f ${serviceName}) -ErrorAction SilentlyContinue
    ${expected} = [ordered]@{
        Application   = Join-Path ${Top} '.venv\Scripts\python.exe'
        AppParameters = ('-m {0}' -f ${SERVICE_MODULE})
        AppDirectory  = ${Top}
    }
    foreach (${key} in ${expected}.Keys) {
        ${actual} = if ($null -ne ${parameters}) { [string]${parameters}.${key} } else { '' }
        if (${actual} -ne ${expected}[${key}]) {
            [void]${issues}.Add(("nssm {0} is '{1}', expected '{2}'" -f ${key}, ${actual}, ${expected}[${key}]))
        }
    }
}

if (${issues}.Count -gt 0) {
    ("mast-service FAIL: " + (${issues} -join '; ')) | Out-File -FilePath ${verifyLog} -Encoding UTF8
    exit 1
}

("mast-service OK: {0} registered, {1}, automatic, running {2}" -f ${serviceName}, ${LOCAL_SYSTEM}, ${SERVICE_MODULE}) |
    Out-File -FilePath ${verifyLog} -Encoding UTF8
Write-MastSmokeOk -Module 'mast-service' | Out-Null
exit 0
