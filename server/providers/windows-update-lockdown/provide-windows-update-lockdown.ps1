#requires -Version 5.1
[CmdletBinding()]
param(
    [string]${TaskName}  = 'mast-no-windows-updates',
    [string]${DeployDir} = 'C:\ProgramData\MAST\windows-update'
)

# Keep automatic Windows Updates disabled on a MAST unit. Because Windows self-heals
# its update components (WaaSMedicSvc / Update Orchestrator re-enable wuauserv), a
# one-time disable drifts back -- so we deploy enforce-no-updates.ps1 and register a
# daily + at-startup SYSTEM scheduled task that re-asserts the disabled state, and we
# run it once now. Bootstrap already did the initial disable; this makes it stick.

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} 'windows-update-lockdown.log'

function Write-WuLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-windows-update-lockdown.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    # 1) Deploy the enforcement script to a persistent path (the scheduled task runs
    #    long after the staging dir is gone).
    ${enforceSrc} = Join-Path ${PSScriptRoot} 'enforce-no-updates.ps1'
    if (-not (Test-Path -LiteralPath ${enforceSrc})) { throw "enforce-no-updates.ps1 not found beside provide script." }
    New-Item -ItemType Directory -Path ${DeployDir} -Force | Out-Null
    ${enforceDst} = Join-Path ${DeployDir} 'enforce-no-updates.ps1'
    Copy-Item -LiteralPath ${enforceSrc} -Destination ${enforceDst} -Force
    Write-WuLog ("Deployed enforcement script: {0}" -f ${enforceDst})

    # 2) Register the daily + at-startup SYSTEM task that re-asserts the state.
    ${argLine} = ('-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "{0}"' -f ${enforceDst})
    ${action}  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ${argLine}
    ${trigDaily}   = New-ScheduledTaskTrigger -Daily -At (Get-Date -Hour 3 -Minute 0 -Second 0)
    ${trigStartup} = New-ScheduledTaskTrigger -AtStartup
    ${principal} = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    ${settings}  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Unregister-ScheduledTask -TaskName ${TaskName} -ErrorAction SilentlyContinue -Confirm:$false
    Register-ScheduledTask -TaskName ${TaskName} `
        -Description 'Re-assert no-automatic-Windows-Updates (best-effort; Windows self-heals update components). Runs daily + at startup as SYSTEM.' `
        -Action ${action} -Trigger @(${trigDaily}, ${trigStartup}) -Principal ${principal} -Settings ${settings} -ErrorAction Stop | Out-Null
    Write-WuLog ("Registered scheduled task '{0}' (daily 03:00 + at startup, SYSTEM)." -f ${TaskName})

    # 3) Apply once now.
    Write-WuLog "Running enforcement once now."
    ${p} = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-WindowStyle', 'Hidden', '-File', ${enforceDst}) `
        -PassThru -Wait -NoNewWindow
    try { ${p}.Refresh() } catch {}
    Write-WuLog ("Enforcement run exit code: {0}" -f ${p}.ExitCode)

    Write-WuLog "Windows Update lockdown provisioning complete."
    exit 0
}
catch {
    ${errorMsg} = ("Windows Update lockdown failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
