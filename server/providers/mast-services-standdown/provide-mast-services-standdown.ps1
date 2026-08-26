#requires -RunAsAdministrator
#requires -Version 5.1
[CmdletBinding()]
param()

# Stand the unit down before the run touches anything: stop every service in the
# stand-down set and set it Disabled. Nothing in a provisioning run is entitled
# to have telescope hardware moving, and a running mast-unit moves it on process
# start (MAST_unit#132). Disabled rather than Manual so a stray Start-Service, a
# reboot, or a dependency chain cannot raise it either; an operator who means to
# bring the unit up enables it deliberately.
#
# Set-Service, not nssm: nssm arrives at order 1200 and this runs at 20.
#
# Failing here fails the module. A unit whose service cannot be stopped is the
# one case this exists to catch, and continuing would provision a machine that
# is commanding hardware the whole time.

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

# Canonical service list + per-service expected start mode (shared with the
# verify script and with mast-services-finalize).
${namesDot} = Join-Path ${PSScriptRoot} 'mast-service-names.ps1'
if (-not (Test-Path ${namesDot})) { throw "mast-service-names.ps1 not found beside provide script." }
. ${namesDot}

${null} = Start-ProvisionLog -Component 'mast-services-standdown'
try {

    ${failures} = New-Object 'System.Collections.Generic.List[string]'

    foreach (${svcName} in (Get-MastStandDownServiceNames)) {
        ${svc} = Get-Service -Name ${svcName} -ErrorAction SilentlyContinue
        if ($null -eq ${svc}) {
            # First provisioning of a unit, or a unit that legitimately lacks the
            # service. There is nothing to stand down and nothing wrong.
            Write-Host ("SKIP {0}: not registered on this unit." -f ${svcName})
            continue
        }

        ${statusBefore} = ${svc}.Status
        ${startBefore} = (Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f ${svcName}) -ErrorAction SilentlyContinue).StartMode
        Write-Host ("{0}: arrived Status={1} StartMode={2}." -f ${svcName}, ${statusBefore}, ${startBefore})

        try {
            if (${statusBefore} -ne 'Stopped') {
                Stop-Service -Name ${svcName} -Force -ErrorAction Stop
            }
            Set-Service -Name ${svcName} -StartupType Disabled -ErrorAction Stop
        }
        catch {
            [void]${failures}.Add(("{0}: {1}" -f ${svcName}, $_.Exception.Message))
            continue
        }

        # Read the end state back rather than trusting the calls: the startup type
        # lives in the registry, not on the cached service object above.
        ${startMode} = (Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f ${svcName}) -ErrorAction SilentlyContinue).StartMode
        ${after} = Get-Service -Name ${svcName} -ErrorAction SilentlyContinue
        ${statusNow} = if ($null -ne ${after}) { ${after}.Status } else { 'unknown' }
        if (${startMode} -ne 'Disabled') {
            [void]${failures}.Add(("{0}: StartMode is '{1}', expected 'Disabled'." -f ${svcName}, ${startMode}))
        }
        elseif (${statusNow} -ne 'Stopped') {
            [void]${failures}.Add(("{0}: Status is '{1}', expected 'Stopped'." -f ${svcName}, ${statusNow}))
        }
        else {
            Write-Host ("OK {0}: StartMode=Disabled Status=Stopped." -f ${svcName})
        }
    }

    if (${failures}.Count -gt 0) {
        Write-Warning ("mast-services-standdown failed for: {0}" -f (${failures} -join '; '))
        exit 1
    }

    Write-Host "mast-services-standdown: the unit is stood down; no MAST service can command hardware during this run."
    exit 0
}
finally {
    Stop-ProvisionLog
}
