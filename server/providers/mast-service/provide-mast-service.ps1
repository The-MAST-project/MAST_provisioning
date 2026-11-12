#requires -RunAsAdministrator
#requires -Version 5.1
[CmdletBinding()]
param(
    [string]${Top} = 'C:\MAST\src',

    # The unit's registry 'supervised' flag, injected by build-mast.ps1.
    [switch]${Supervised}
)

# Install or remove the supervisor's service, never start it: standdown (20) stops it
# and finalize (9500) starts it, so a run brackets every change with the service down.
#
# The registration itself (nssm install, LocalSystem, automatic start, the stop and
# restart parameters) belongs to MAST_supervision, whose installer this runs. Removal
# does not go through that installer's -Uninstall: a unit taken off supervision may
# hold a checkout that predates the installer, and removal must still work there.

try {
    ${provLocal}  = Join-Path ${PSScriptRoot} 'provisioning.psm1'
    ${provGlobal} = 'C:\ProgramData\MAST\provisioning.psm1'
    if (Test-Path ${provLocal}) {
        Import-Module ${provLocal} -Force -ErrorAction Stop -DisableNameChecking
    }
    elseif (Test-Path ${provGlobal}) {
        Import-Module ${provGlobal} -Force -ErrorAction Stop -DisableNameChecking
    }
    else {
        throw "provisioning.psm1 not found next to script or in ${provGlobal}"
    }
}
catch {
    throw "Failed to import provisioning.psm1: $($_.Exception.Message)"
}

${namesDot} = Join-Path ${PSScriptRoot} 'mast-service-names.ps1'
if (-not (Test-Path ${namesDot})) { throw "mast-service-names.ps1 not found beside provide script." }
. ${namesDot}

${serviceName} = Get-MastSupervisorServiceName

${null} = Start-ProvisionLog -Component 'mast-service'
try {
    if (-not ${Supervised}) {
        ${state} = Remove-MastService -Name (Get-MastSupervisorServiceName)
        Write-Host ("{0}: {1} (unit not supervised)" -f ${serviceName}, ${state})
        if (${state} -eq 'pending-delete') {
            Write-Warning ("{0}: deletion is pending -- still registered, and the unit needs a reboot to finish it" -f ${serviceName})
            exit 1
        }
        if (${state} -like 'error:*') {
            Write-Warning ("{0}: {1}" -f ${serviceName}, ${state})
            exit 1
        }
        exit 0
    }

    ${installer} = Join-Path ${Top} 'supervision\install\install-mast-service.ps1'
    if (-not (Test-Path -LiteralPath ${installer})) {
        Write-Warning ("{0}: the unit is supervised but its supervision checkout has no installer at {1}. Pin MAST_supervision in tools/mast-repos.tsv at a revision that carries install\install-mast-service.ps1, or clear the unit's supervised flag." -f ${serviceName}, ${installer})
        exit 1
    }

    Write-Host ("{0}: running {1}" -f ${serviceName}, ${installer})
    & powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -File ${installer}
    ${rc} = ${LASTEXITCODE}
    if (${rc} -ne 0) {
        Write-Warning ("{0}: the installer exited {1}" -f ${serviceName}, ${rc})
        exit 1
    }
    exit 0
}
finally {
    Stop-ProvisionLog
}
