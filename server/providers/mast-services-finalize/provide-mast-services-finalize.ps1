#requires -RunAsAdministrator
#requires -Version 5.1
[CmdletBinding()]
param(
    # The unit's registry 'supervised' flag, injected by build-mast.ps1.
    [switch]${Supervised}
)

# Final operational step of a provisioning run: assert that no legacy MAST nssm
# service is registered on the unit. mast-services-standdown removed them at order
# 20, before any module installed anything, and the driver did the same over the
# transport before the build and transfer; nothing in a run registers one. This is
# the end-of-run check that the posture actually held.
#
# It asserts rather than applies, deliberately. Removal has one owner -- order 20 --
# and a second remover here would hide a provider that had quietly re-registered a
# service mid-run, which is exactly what this is meant to surface. See issue #159.
#
# The supervisor's mast-service is the one service provisioning runs. On a supervised
# unit it must be registered (by the mast-service provider) and is started here,
# after every module that could hold its files has finished; standdown stopped it at
# order 20. On any other unit it must be absent. A failure in an earlier module does
# not skip this: the unit-side loop runs every command. Only a run that dies outright
# leaves the service stopped, until the next run or a reboot starts it.
#
# Runs at order 9500: after all validation (2900/3000) and the proxy finalize (9000),
# before reboot detection (9999).

# --- Import shared helpers ---
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

# Canonical service names and the nssm gate for the legacy ones (shared with the
# verify script and with mast-services-standdown).
${namesDot} = Join-Path ${PSScriptRoot} 'mast-service-names.ps1'
if (-not (Test-Path ${namesDot})) { throw "mast-service-names.ps1 not found beside provide script." }
. ${namesDot}

${null} = Start-ProvisionLog -Component 'mast-services-finalize'
try {
    ${failures} = New-Object 'System.Collections.Generic.List[string]'

    ${remaining} = Get-MastRegisteredServiceNames
    if (${remaining}.Count -gt 0) {
        [void]${failures}.Add(("legacy MAST services are still registered at the end of the run: {0}" -f (${remaining} -join ', ')))
    }

    # Independent of the legacy check: a supervised unit is not left without its
    # supervisor because an unrelated registration failed the run.
    ${supervisorService} = Get-MastSupervisorServiceName
    ${registered} = Get-Service -Name (Get-MastSupervisorServiceName) -ErrorAction SilentlyContinue
    if (${Supervised}) {
        if ($null -eq ${registered}) {
            [void]${failures}.Add(("{0} is not registered on a supervised unit; see the mast-service module's log" -f ${supervisorService}))
        }
        else {
            try {
                Start-Service -Name (Get-MastSupervisorServiceName) -ErrorAction Stop
                Write-Host ("{0}: started" -f ${supervisorService})
            }
            catch {
                [void]${failures}.Add(("{0}: start failed: {1}" -f ${supervisorService}, $_.Exception.Message))
            }
        }
    }
    elseif ($null -ne ${registered}) {
        [void]${failures}.Add(("{0} is registered on a unit that is not supervised" -f ${supervisorService}))
    }

    if (${failures}.Count -gt 0) {
        Write-Warning ("mast-services-finalize: {0}" -f (${failures} -join '; '))
        exit 1
    }

    if (${Supervised}) {
        Write-Host ("mast-services-finalize: no legacy MAST service is registered, and {0} is running." -f ${supervisorService})
    }
    else {
        Write-Host "mast-services-finalize: no MAST service is registered; the unit ships with nothing that can command hardware."
    }
    exit 0
}
finally {
    Stop-ProvisionLog
}
