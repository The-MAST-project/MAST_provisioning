# Canonical inventory of the MAST nssm services, and the single source of truth for
# the only thing provisioning does with them: remove them. Shared by the two
# providers that act on it -- mast-services-standdown (order 20) removes them before
# any module installs anything, and mast-services-finalize (9500) asserts at the end
# of a run that none came back. Staged into both by `repofiles`.
#
# Why removal rather than a start mode: none of these four processes is started by
# its service. The unit is run by hand and raises PWI4, ps3cli and PHD2 itself
# (MAST_unit/src/app.py, MAST_unit/src/phd2/phd2.py), and PWShutter has had no
# consumer since the covers moved to PWI4's mirrorcover API (MAST_unit#134). A
# registered service is therefore a COMPETING path rather than a redundant one:
# ensure_process_is_running adopts by name, so a session-0 PWI4 raised by mast-pwi4
# is adopted by a hand-run unit and the operator gets one that can neither draw nor
# see Z:. See issue #159.
#
# mast-unit is listed first so it is stopped ahead of mast-pwi4. Nothing enforces
# that today -- `nssm set ... AppDependencies` is a no-op on nssm 2.24, whose valid
# parameter is DependOnService -- but the order costs nothing to keep.
function Get-MastServiceNames {
    @('mast-unit', 'mast-pwi4', 'mast-pwshutter', 'mast-phd2')
}

# The names an earlier provisioning generation registered, before the mast-* prefix.
# A unit that predates that migration still carries these, registered
# SERVICE_AUTO_START -- so removing only the mast-* names would leave an
# auto-starting service behind on exactly the units that most need it gone.
#
# Unlike the mast-* names these are not unambiguous: 'PHD2' is a plausible name for a
# service installed by something other than this repo. They are removed only when the
# registration is demonstrably ours -- see Test-MastNssmService.
function Get-MastLegacyServiceNames {
    @('PWI4', 'PWShutter', 'PHD2')
}

# True when a registered service is nssm-hosted, which is the signature of one this
# repo installed: nssm.exe is the service binary and the real application lives under
# the service's own Parameters key. Used to gate removal of the ambiguous legacy
# names; the mast-* names need no gate.
function Test-MastNssmService {
    param([Parameter(Mandatory)][string]${Name})

    ${svc} = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f ${Name}) -ErrorAction SilentlyContinue
    if ($null -eq ${svc}) { return $false }
    return (${svc}.PathName -match 'nssm\.exe')
}

# The MAST services still registered on this unit: every mast-* name that exists,
# plus any legacy name that exists and is nssm-hosted. An EMPTY result is the posture
# provisioning owes, and is what both mast-services-standdown's verify and
# mast-services-finalize assert. An unprovisioned unit and a cleaned one are
# indistinguishable here, which is the intent.
function Get-MastRegisteredServiceNames {
    ${found} = New-Object 'System.Collections.Generic.List[string]'
    foreach (${name} in (Get-MastServiceNames)) {
        if ($null -ne (Get-Service -Name ${name} -ErrorAction SilentlyContinue)) {
            [void]${found}.Add(${name})
        }
    }
    foreach (${name} in (Get-MastLegacyServiceNames)) {
        if (($null -ne (Get-Service -Name ${name} -ErrorAction SilentlyContinue)) -and (Test-MastNssmService -Name ${name})) {
            [void]${found}.Add(${name})
        }
    }
    @(${found})
}

# Stop a service and delete its registration, reporting what actually happened.
#
# 'sc.exe' is spelled with the extension deliberately: bare 'sc' is a PowerShell
# alias for Set-Content. Remove-Service would be the cmdlet, but it is PowerShell 6+
# and the fleet runs 5.1. Deleting the service key takes nssm's Parameters subkey
# with it, so no separate cleanup is needed.
function Remove-MastService {
    param([Parameter(Mandatory)][string]${Name})

    ${svc} = Get-Service -Name ${Name} -ErrorAction SilentlyContinue
    if ($null -eq ${svc}) { return 'absent' }

    if (${svc}.Status -ne 'Stopped') {
        try { Stop-Service -Name ${Name} -Force -ErrorAction Stop }
        catch { return ("error: stop failed: {0}" -f $_.Exception.Message) }
    }

    # Isolate the native call: 2>&1 captures sc.exe's text, but under
    # ErrorActionPreference=Stop a NativeCommandError would still terminate the
    # script before the read-back below.
    ${prevEap} = ${ErrorActionPreference}
    try {
        ${ErrorActionPreference} = 'Continue'
        ${out} = (& sc.exe delete ${Name} 2>&1 | Out-String).Trim()
        ${rc}  = ${LASTEXITCODE}
    }
    finally {
        ${ErrorActionPreference} = ${prevEap}
    }
    if (${rc} -ne 0) { return ("error: sc delete exit {0}: {1}" -f ${rc}, ${out}) }

    # sc.exe reports success for a delete it has only MARKED: a service with an open
    # handle elsewhere stays registered until the last handle closes, in practice
    # until a reboot. Read the registration back rather than trusting the exit code,
    # so the run never claims a removal that has not happened.
    if ($null -ne (Get-Service -Name ${Name} -ErrorAction SilentlyContinue)) {
        return 'pending-delete'
    }
    return 'removed'
}
