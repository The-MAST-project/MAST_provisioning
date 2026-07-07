#requires -RunAsAdministrator
#requires -Version 5.1
[CmdletBinding()]
param()

# Final operational step of a provisioning run. Every MAST service is registered
# (by the phd2 / planewave / mast providers) as SERVICE_AUTO_START and started, so
# that each provider's own verification -- and the diagnostics / validation steps --
# run against LIVE services. Once all of that has passed, this provider flips the
# services to MANUAL start and stops them, so a provisioned unit ships quiescent and
# does not auto-raise telescope services on boot (an operator brings them up by hand
# in the wanted order).
#
# TEMPORARY (current development stage): manual start is deliberate for now. Once the
# services are battle-tested we intend to restore automatic start -- expect this
# provider to be removed or relaxed in a future stage (months out, at least).
#
# Runs at order 9500: after all validation (2900/3000) and the proxy finalize (9000),
# before reboot detection (9999). Nothing after it needs the services running.

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

# Canonical service list (shared with the verify script).
${namesDot} = Join-Path ${PSScriptRoot} 'mast-service-names.ps1'
if (-not (Test-Path ${namesDot})) { throw "mast-service-names.ps1 not found beside provide script." }
. ${namesDot}

${log} = Start-ProvisionLog -Component 'mast-services-finalize'
try {
    ${services} = Get-MastServiceNames
    ${failures} = New-Object 'System.Collections.Generic.List[string]'

    foreach (${svcName} in ${services}) {
        ${svc} = Get-Service -Name ${svcName} -ErrorAction SilentlyContinue
        if ($null -eq ${svc}) {
            # A unit may legitimately lack a service (e.g. no PWShutter). Not an error.
            Write-Host ("SKIP {0}: not registered on this unit." -f ${svcName})
            continue
        }

        try {
            Set-Service -Name ${svcName} -StartupType Manual -ErrorAction Stop
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
        if (${startMode} -ne 'Manual') {
            [void]${failures}.Add(("{0}: StartMode is '{1}', expected 'Manual'." -f ${svcName}, ${startMode}))
        }
        elseif (${statusNow} -ne 'Stopped') {
            [void]${failures}.Add(("{0}: Status is '{1}', expected 'Stopped'." -f ${svcName}, ${statusNow}))
        }
        else {
            Write-Host ("OK {0}: StartMode=Manual Status=Stopped." -f ${svcName})
        }
    }

    if (${failures}.Count -gt 0) {
        Write-Warning ("mast-services-finalize failed for: {0}" -f (${failures} -join '; '))
        exit 1
    }

    Write-Host "mast-services-finalize: all present MAST services set to Manual and stopped."
    exit 0
}
finally {
    Stop-ProvisionLog
}
