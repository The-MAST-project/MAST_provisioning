#requires -Version 5.1
# Migrate an already-provisioned unit's MAST NSSM services to the mast-* naming and
# the current-development-stage MANUAL start policy, to match what a freshly
# provisioned unit produces. Self-contained (no module imports) so it ships as a
# single .ps1 via tools/run-remote-script-winrm.py OR over SSH (vm_lib.SshSession).
#
# Approach is deterministic and SAFE: for each service it discovers the installed
# .exe (as the providers do), registers the mast-* service FIRST and verifies it
# exists, and only THEN removes the legacy-named service. So a failed install never
# leaves the unit with the old service removed and nothing in its place. Settings
# mirror the phd2 / planewave / mast providers. Idempotent; re-running is a no-op.
#
# NOTE: manual start is a deliberate current-development-stage measure; once the
# services are battle-tested we intend to return them to automatic start. This
# mirrors the mast-services-finalize provider used on fresh provisioning.
#
# Legacy -> new:  PWI4 -> mast-pwi4,  PWShutter -> mast-pwshutter,  PHD2 -> mast-phd2
# (mast-unit is already conformant; it is only set manual + stopped here.)
#
# Dependency note: the providers' `nssm set mast-unit AppDependencies ...` is a NO-OP
# on nssm 2.24 (the valid parameter is DependOnService), so a provisioned unit has no
# inter-service dependency today. Wiring an ordered launch / dependency tree is the
# deferred second slice of MAST_provisioning#5, so this tool deliberately does NOT set
# one -- it keeps mast02 matching a fresh box.
#
# Usage (from the provisioning host):
#   python tools/run-remote-script-winrm.py --host mast02 --vault vault/creds.json \
#       --script tools/rename-mast-services.ps1
#   Add:  --invoke-args="-DryRun"   to preview without changing anything.
[CmdletBinding()]
param(
    [switch]${DryRun},
    [string]${NssmExe} = 'C:\Program Files\nssm\nssm.exe'
)
# nssm writes status to stderr; do not let a native stderr write become a
# terminating error (it would under 'Stop' in PS 5.1).
${ErrorActionPreference} = 'Continue'

# new name -> definition. Order does not matter for the rename; the final quiesce
# loop below stops mast-unit first (it is the dependent).
${defs} = @(
    @{ New = 'mast-pwi4';      Legacy = 'PWI4';      Filter = 'PWI4.exe';      Log = 'pwi4' },
    @{ New = 'mast-pwshutter'; Legacy = 'PWShutter'; Filter = 'PWShutter.exe'; Log = 'pwshutter' },
    @{ New = 'mast-phd2';      Legacy = 'PHD2';      Filter = 'phd2.exe';      Log = 'phd2' }
)
${finalServices} = @('mast-unit', 'mast-pwi4', 'mast-pwshutter', 'mast-phd2')

function Write-Step { param([string]${Msg}) Write-Host ("[rename-mast-services] {0}" -f ${Msg}) }

function Invoke-Nssm {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]${NssmArgs})
    if (${DryRun}) {
        Write-Step ("DRYRUN nssm {0}" -f (${NssmArgs} -join ' '))
        return
    }
    ${out} = & ${NssmExe} @NssmArgs 2>&1
    foreach (${line} in ${out}) {
        # nssm.exe writes UTF-16LE; strip interleaved NULs for a readable log line.
        Write-Step ("  nssm: {0}" -f ((${line} | Out-String) -replace "`0", '').Trim())
    }
}

if (-not (Test-Path -LiteralPath ${NssmExe})) {
    throw "nssm.exe not found at ${NssmExe}; cannot migrate services."
}

foreach (${d} in ${defs}) {
    ${new}    = ${d}.New
    ${legacy} = ${d}.Legacy

    if ($null -ne (Get-Service -Name ${new} -ErrorAction SilentlyContinue)) {
        Write-Step ("SKIP {0}: already exists (migrated)." -f ${new})
    }
    else {
        ${exe} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
            -Recurse -Filter ${d}.Filter -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
        if (-not ${exe}) {
            ${legacyPresent} = ($null -ne (Get-Service -Name ${legacy} -ErrorAction SilentlyContinue))
            if (${legacyPresent}) {
                throw ("Cannot create {0}: {1} not found on disk, and legacy {2} still present -- refusing to leave the unit serviceless." -f ${new}, ${d}.Filter, ${legacy})
            }
            Write-Step ("SKIP {0}: neither {0} nor {1} present, and {2} not installed." -f ${new}, ${legacy}, ${d}.Filter)
            continue
        }

        Write-Step ("CREATE {0} -> {1}" -f ${new}, ${exe})
        Invoke-Nssm install ${new} ${exe}
        if (-not ${DryRun} -and ($null -eq (Get-Service -Name ${new} -ErrorAction SilentlyContinue))) {
            throw ("nssm install failed for {0} (exe={1}); legacy {2} left untouched." -f ${new}, ${exe}, ${legacy})
        }
        Invoke-Nssm set ${new} Start SERVICE_DEMAND_START
        Invoke-Nssm set ${new} Type SERVICE_INTERACTIVE_PROCESS
        Invoke-Nssm set ${new} AppStdout ("C:\MAST\logs\{0}_stdout.log" -f ${d}.Log)
        Invoke-Nssm set ${new} AppStderr ("C:\MAST\logs\{0}_stderr.log" -f ${d}.Log)
        Invoke-Nssm set ${new} AppRotateFiles 1
        Invoke-Nssm set ${new} AppRotateBytes 10485760
    }

    # Only now, with the new service in place, retire the legacy one.
    if ($null -ne (Get-Service -Name ${legacy} -ErrorAction SilentlyContinue)) {
        Write-Step ("REMOVE legacy {0}" -f ${legacy})
        Invoke-Nssm stop ${legacy}
        Invoke-Nssm remove ${legacy} confirm
    }
}

# Ensure every present MAST service is Manual + Stopped (mast-unit first).
foreach (${svcName} in ${finalServices}) {
    ${svc} = Get-Service -Name ${svcName} -ErrorAction SilentlyContinue
    if ($null -eq ${svc}) {
        Write-Step ("SKIP quiesce {0}: not present." -f ${svcName})
        continue
    }
    if (${DryRun}) {
        Write-Step ("DRYRUN would set {0} -StartupType Manual and stop it." -f ${svcName})
        continue
    }
    Set-Service -Name ${svcName} -StartupType Manual -ErrorAction SilentlyContinue
    if (${svc}.Status -ne 'Stopped') { Stop-Service -Name ${svcName} -Force -ErrorAction SilentlyContinue }
    ${startMode} = (Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f ${svcName}) -ErrorAction SilentlyContinue).StartMode
    ${after} = Get-Service -Name ${svcName} -ErrorAction SilentlyContinue
    Write-Step ("{0}: StartMode={1} Status={2}" -f ${svcName}, ${startMode}, ${after}.Status)
}

Write-Step "Done."
exit 0
