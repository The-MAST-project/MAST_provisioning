#requires -Version 5.1
# Re-assert the "no automatic Windows Updates" state on a MAST unit. Windows
# self-heals its update components (WaaSMedicSvc / Update Orchestrator re-enable
# wuauserv and re-create scan tasks), so there is NO permanent one-shot disable --
# this is best-effort and is re-run daily (and at startup) by the
# 'mast-no-windows-updates' scheduled task the provider registers. Runs as SYSTEM.
[CmdletBinding()]
param()
${ErrorActionPreference} = 'Continue'

# 1) Group Policy knob -- honored on Pro/Enterprise/Education; the most durable lever.
${au} = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path ${au} -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path ${au} -Name 'NoAutoUpdate'                  -Value 1 -Type DWord -ErrorAction SilentlyContinue
Set-ItemProperty -Path ${au} -Name 'AUOptions'                     -Value 1 -Type DWord -ErrorAction SilentlyContinue   # 1 = never check
Set-ItemProperty -Path ${au} -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1 -Type DWord -ErrorAction SilentlyContinue

# 2) Stop + disable the update services. WaaSMedicSvc is protected (Set-Service will
#    likely be denied and it may re-enable itself) -- we still try; the daily re-run
#    corrects drift. wuauserv/UsoSvc disable is what actually blocks scans in practice.
foreach (${svc} in 'wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'uhssvc') {
    try { Stop-Service -Name ${svc} -Force -ErrorAction SilentlyContinue } catch {}
    try { Set-Service  -Name ${svc} -StartupType Disabled -ErrorAction SilentlyContinue } catch {}
}

# 3) Disable the scheduled tasks that trigger scans/downloads/installs/reboots. The OS
#    can re-create them, so this is re-asserted on every run too.
foreach (${p} in '\Microsoft\Windows\UpdateOrchestrator\', '\Microsoft\Windows\WindowsUpdate\') {
    foreach (${t} in (Get-ScheduledTask -TaskPath ${p} -ErrorAction SilentlyContinue)) {
        try { Disable-ScheduledTask -TaskName ${t}.TaskName -TaskPath ${t}.TaskPath -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
}

# Breadcrumb so drift/enforcement is auditable.
${logDir} = Join-Path ${env:SystemDrive} 'MAST\logs\windows-update'
New-Item -ItemType Directory -Path ${logDir} -Force -ErrorAction SilentlyContinue | Out-Null
${wu}   = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
${mode} = (Get-CimInstance -ClassName Win32_Service -Filter "Name='wuauserv'" -ErrorAction SilentlyContinue).StartMode
${status} = if (${wu}) { ${wu}.Status } else { 'absent' }
Add-Content -LiteralPath (Join-Path ${logDir} 'enforce.log') -Encoding UTF8 `
    -Value ("[{0}] enforced no-updates; wuauserv StartMode={1} Status={2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ${mode}, ${status})
exit 0
