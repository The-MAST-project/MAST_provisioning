#requires -RunAsAdministrator
#requires -Version 5.1
[CmdletBinding()]
param()

# Final operational step of a provisioning run: every MAST service ends Stopped, at
# the start mode the shared table in mast-service-names.ps1 says provisioning owes
# it. mast-unit is Disabled and was never started -- mast-services-standdown (order
# 20) stood it down before the first module and the mast provider registers it that
# way, because process start commands hardware (MAST_unit#132) and no interlock
# exists to make that safe. The three prerequisite services are registered
# auto-start and started by the phd2 / planewave providers so their own verifies run
# against a live service, and are flipped to Manual here.
#
# So this provider owns run state, not registration, and its job at 9500 is to leave
# the posture asserted rather than merely applied: a unit ships quiescent, and the
# one service that can move a telescope cannot be started by accident.
#
# Runs at order 9500: after all validation (2900/3000) and the proxy finalize (9000),
# before reboot detection (9999). Nothing after it needs any service running.

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

# Canonical service list + per-service expected start mode (shared with the verify
# script and with mast-services-standdown).
${namesDot} = Join-Path ${PSScriptRoot} 'mast-service-names.ps1'
if (-not (Test-Path ${namesDot})) { throw "mast-service-names.ps1 not found beside provide script." }
. ${namesDot}

${null} = Start-ProvisionLog -Component 'mast-services-finalize'
try {
    ${expectations} = Get-MastServiceExpectations
    ${failures} = New-Object 'System.Collections.Generic.List[string]'

    foreach (${svcName} in ${expectations}.Keys) {
        ${expected} = ${expectations}[${svcName}]
        ${svc} = Get-Service -Name ${svcName} -ErrorAction SilentlyContinue
        if ($null -eq ${svc}) {
            # A unit may legitimately lack a service (e.g. no PWShutter). Not an error.
            Write-Host ("SKIP {0}: not registered on this unit." -f ${svcName})
            continue
        }

        try {
            Set-Service -Name ${svcName} -StartupType ${expected} -ErrorAction Stop
            if (${svc}.Status -ne 'Stopped') {
                Stop-Service -Name ${svcName} -Force -ErrorAction Stop
            }
        }
        catch {
            [void]${failures}.Add(("{0}: {1}" -f ${svcName}, $_.Exception.Message))
            continue
        }

        # Confirm the end state (startup type is read from the registry, not the
        # cached object above).
        ${startMode} = (Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f ${svcName}) -ErrorAction SilentlyContinue).StartMode
        ${after} = Get-Service -Name ${svcName} -ErrorAction SilentlyContinue
        ${statusNow} = if ($null -ne ${after}) { ${after}.Status } else { 'unknown' }
        if (${startMode} -ne ${expected}) {
            [void]${failures}.Add(("{0}: StartMode is '{1}', expected '{2}'." -f ${svcName}, ${startMode}, ${expected}))
        }
        elseif (${statusNow} -ne 'Stopped') {
            [void]${failures}.Add(("{0}: Status is '{1}', expected 'Stopped'." -f ${svcName}, ${statusNow}))
        }
        else {
            Write-Host ("OK {0}: StartMode={1} Status=Stopped." -f ${svcName}, ${startMode})
        }
    }

    if (${failures}.Count -gt 0) {
        Write-Warning ("mast-services-finalize failed for: {0}" -f (${failures} -join '; '))
        exit 1
    }

    Write-Host "mast-services-finalize: all present MAST services stopped, at their expected start modes."
    exit 0
}
finally {
    Stop-ProvisionLog
}
