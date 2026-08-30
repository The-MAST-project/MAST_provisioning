#requires -RunAsAdministrator
#requires -Version 5.1
[CmdletBinding()]
param()

# Final operational step of a provisioning run: assert that no MAST nssm service is
# registered on the unit. mast-services-standdown removed them at order 20, before
# any module installed anything, and the driver did the same over the transport
# before the build and transfer; nothing in a run registers one. This is the
# end-of-run check that the posture actually held.
#
# It asserts rather than applies, deliberately. Removal has one owner -- order 20 --
# and a second remover here would hide a provider that had quietly re-registered a
# service mid-run, which is exactly what this is meant to surface. See issue #159.
#
# Runs at order 9500: after all validation (2900/3000) and the proxy finalize (9000),
# before reboot detection (9999). Nothing after it needs any service.

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
    ${remaining} = Get-MastRegisteredServiceNames

    if (${remaining}.Count -gt 0) {
        Write-Warning ("mast-services-finalize: MAST services are still registered at the end of the run: {0}" -f (${remaining} -join ', '))
        exit 1
    }

    Write-Host "mast-services-finalize: no MAST service is registered; the unit ships with nothing that can command hardware."
    exit 0
}
finally {
    Stop-ProvisionLog
}
