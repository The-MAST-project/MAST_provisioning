#requires -Version 5.1
# The one statement of "Microsoft Edge's self-update is off" (MAST_provisioning#230).
# Edge Update is its own updater, outside Windows Update, so the Windows Update
# lockdown does not stop it. Dot-sourced by enforce-no-updates.ps1 (which asserts it),
# verify-windows-update-lockdown.ps1 (which checks it) and mast-os-patch-probe.ps1
# (which reports it), so the three cannot disagree about what "off" means.
#
# The lever is the updater's services and scheduled tasks, not its policy: Edge Update
# reads HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate only on an enterprise-managed
# machine, and the units are standalone (on mast01 it logs "Machine is not Enterprise
# Managed" with every value set). Edge itself stays installed and usable -- people
# still open it -- it just no longer changes under them.

${script:MastEdgeUpdateServices} = @('edgeupdate', 'edgeupdatem')
${script:MastEdgeUpdateTaskPattern} = 'MicrosoftEdgeUpdateTaskMachine*'
${script:MastServiceDisabled} = 'Disabled'

# A service Windows does not have cannot update anything, so absent counts as off.
function Test-MastEdgeUpdateOff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]${ServiceModes},
        [Parameter(Mandatory)][int]${EnabledTaskCount}
    )
    foreach (${mode} in ${ServiceModes}.Values) {
        if ($null -ne ${mode} -and ${mode} -ne ${script:MastServiceDisabled}) { return $false }
    }
    return (${EnabledTaskCount} -eq 0)
}

function Disable-MastEdgeUpdate {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess('Edge Update services and tasks', 'Disable')) { return }
    foreach (${svc} in ${script:MastEdgeUpdateServices}) {
        if (-not (Get-Service -Name ${svc} -ErrorAction SilentlyContinue)) { continue }
        Stop-Service -Name ${svc} -Force -ErrorAction SilentlyContinue
        Set-Service -Name ${svc} -StartupType ${script:MastServiceDisabled}
    }
    foreach (${t} in @(Get-ScheduledTask -TaskName ${script:MastEdgeUpdateTaskPattern} -ErrorAction SilentlyContinue)) {
        Disable-ScheduledTask -TaskName ${t}.TaskName -TaskPath ${t}.TaskPath | Out-Null
    }
}

function Get-MastEdgeUpdateState {
    [CmdletBinding()]
    param()
    ${modes} = [ordered]@{}
    foreach (${svc} in ${script:MastEdgeUpdateServices}) {
        ${c} = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f ${svc}) -ErrorAction SilentlyContinue
        ${modes}[${svc}] = $(if (${c}) { [string]${c}.StartMode } else { $null })
    }
    ${tasks} = @(Get-ScheduledTask -TaskName ${script:MastEdgeUpdateTaskPattern} -ErrorAction SilentlyContinue)
    ${enabled} = @(${tasks} | Where-Object { $_.State -ne 'Disabled' }).Count
    return [ordered]@{
        edgeupdate    = ${modes}['edgeupdate']
        edgeupdatem   = ${modes}['edgeupdatem']
        tasks_enabled = ${enabled}
        off           = Test-MastEdgeUpdateOff -ServiceModes ${modes} -EnabledTaskCount ${enabled}
    }
}
