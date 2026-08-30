#requires -RunAsAdministrator
#requires -Version 5.1
[CmdletBinding()]
param()

# Stand the unit down before the run touches anything: remove every MAST nssm
# service. Nothing in a provisioning run is entitled to have telescope hardware
# moving, and a running mast-unit moves it on process start (MAST_unit#132). Removal
# rather than a start mode because nothing starts these services in the first place
# -- the unit raises PWI4, ps3cli and PHD2 itself, and a leftover registration is a
# competing path into the same processes (issue #159, and the header of
# mast-service-names.ps1).
#
# Set-Service and sc.exe, not nssm: nssm arrives at order 1200 and this runs at 20.
#
# Failing here fails the module. A unit whose services cannot be removed is the one
# case this exists to catch, and continuing would provision a machine that can still
# command hardware.

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

# Canonical service names, the nssm gate for the legacy ones, and Remove-MastService
# (shared with the verify script and with mast-services-finalize).
${namesDot} = Join-Path ${PSScriptRoot} 'mast-service-names.ps1'
if (-not (Test-Path ${namesDot})) { throw "mast-service-names.ps1 not found beside provide script." }
. ${namesDot}

${null} = Start-ProvisionLog -Component 'mast-services-standdown'
try {

    ${failures} = New-Object 'System.Collections.Generic.List[string]'

    # The mast-* names are unambiguous and are always attempted. A legacy name is
    # attempted only when it is registered AND nssm-hosted, which is what proves the
    # registration is one of ours rather than someone else's service of the same name.
    ${targets} = New-Object 'System.Collections.Generic.List[string]'
    foreach (${svcName} in (Get-MastServiceNames)) { [void]${targets}.Add(${svcName}) }
    foreach (${svcName} in (Get-MastLegacyServiceNames)) {
        if ($null -eq (Get-Service -Name ${svcName} -ErrorAction SilentlyContinue)) {
            Write-Host ("{0}: absent (legacy name)" -f ${svcName})
            continue
        }
        if (-not (Test-MastNssmService -Name ${svcName})) {
            Write-Host ("{0}: left alone -- registered but not nssm-hosted, so not ours" -f ${svcName})
            continue
        }
        [void]${targets}.Add(${svcName})
    }

    foreach (${svcName} in ${targets}) {
        ${state} = Remove-MastService -Name ${svcName}
        Write-Host ("{0}: {1}" -f ${svcName}, ${state})
        if (${state} -eq 'pending-delete') {
            [void]${failures}.Add(("{0}: deletion is pending -- still registered, and the unit needs a reboot to finish it" -f ${svcName}))
        }
        elseif (${state} -like 'error:*') {
            [void]${failures}.Add(("{0}: {1}" -f ${svcName}, ${state}))
        }
    }

    if (${failures}.Count -gt 0) {
        Write-Warning ("mast-services-standdown failed for: {0}" -f (${failures} -join '; '))
        exit 1
    }

    Write-Host "mast-services-standdown: no MAST service is registered on this unit."
    exit 0
}
finally {
    Stop-ProvisionLog
}
