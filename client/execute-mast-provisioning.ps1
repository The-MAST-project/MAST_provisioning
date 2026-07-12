[CmdletBinding()]
param(
    [string]${StagingPath}       = ".",
    [string]${ProvServer}        = "",
    [string]${SmbUser}           = "",
    [string]${SmbPass}           = "",
    [string]${Modules}           = "",  # comma-separated; empty = all modules
    [string]${RunId}             = "",  # autonomous: server passes its run id; manual: auto-generated
    [string]${HeldBy}            = "",  # hostname of orchestrator; defaults to local computer
    [int]   ${LeaseTtlSeconds}   = 7200, # 2 h default; comfortably covers a ~40 min provisioning run on a slow VM without an in-process renewer
    [switch]${AllowReboot}              # if the reboot provider dropped a flag and the run succeeded, schedule a reboot before exit
)

${ErrorActionPreference} = "Stop"

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) {
    ${mastLogDot} = Join-Path ${PSScriptRoot} '..\server\lib\mast-log.ps1'
}
if (-not (Test-Path ${mastLogDot})) {
    throw "mast-log.ps1 not found (expected next to this script or under server\lib)."
}
. ${mastLogDot}

${invokeDot} = Join-Path ${PSScriptRoot} 'mast-invoke-child.ps1'
if (-not (Test-Path ${invokeDot})) {
    ${invokeDot} = Join-Path ${PSScriptRoot} '..\client\mast-invoke-child.ps1'
}
if (-not (Test-Path ${invokeDot})) {
    throw "mast-invoke-child.ps1 not found (expected next to this script or under client)."
}
. ${invokeDot}

# When the orchestrator supplies a run id, key the unit-side session dir on it
# (C:\MAST\logs\sessions\<run-id>) so the controller can archive this exact dir
# back under its own per-run log tree. A manual run (no -RunId) keeps the
# timestamp-named dir. Honors an explicit MAST_LOG_SESSION_DIR override if set.
if (-not [string]::IsNullOrWhiteSpace(${RunId}) -and
    [string]::IsNullOrWhiteSpace(${env:MAST_LOG_SESSION_DIR})) {
    ${env:MAST_LOG_SESSION_DIR} = Join-Path (Get-MastLogsBase) ("sessions\" + ${RunId})
}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${smokeDir} = Get-MastSmokeDir
# Pre-create verify dir too: per-provider verify commands (module.json) run as
# separate powershell.exe children that do not dot-source mast-log.ps1, so they
# cannot call Get-MastVerifyDir themselves and will crash on Out-File if the
# directory does not exist (seen in ascom verify, 2026-05-17 run).
${verifyDir} = Get-MastVerifyDir
${logFile} = Join-Path ${logDir} "provisioning-execute.log"

# State under <SystemDrive>\MAST (same tree as logs); installed-manifest lives here.
${mastRoot} = Join-Path ${env:SystemDrive} "MAST"
${null} = New-Item -ItemType Directory -Path ${mastRoot} -Force -ErrorAction SilentlyContinue

# Sweep prior lock-file artifacts from before the lease-record migration so an
# upgraded unit does not have a stray file confusing operators.
foreach (${legacyLock} in @(
    (Join-Path ${env:ProgramData} 'MAST\execute.lock'),
    (Join-Path ${mastRoot}        'execute.lock')
)) {
    if (Test-Path ${legacyLock}) {
        try { Remove-Item -Force ${legacyLock} -ErrorAction Stop }
        catch { Write-Warning "Could not remove legacy lock at ${legacyLock}: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------
# Execute-lease acquire. The lease replaces the old sticky lock file: it
# carries an expiry, the run id that owns it, and the pid so a crashed run
# can be detected and taken over on the next cycle instead of blocking the
# fleet until a human intervenes.
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace(${RunId})) {
    ${RunId} = "exec-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$PID"
}
if ([string]::IsNullOrWhiteSpace(${HeldBy})) {
    ${HeldBy} = ${env:COMPUTERNAME}
}
${leasePath} = Get-MastExecuteLeasePath

function New-LeaseObject {
    param([string]$RunId, [string]$HeldBy, [int]$TtlSeconds)
    $startedUtc = (Get-Date).ToUniversalTime()
    $expiresUtc = $startedUtc.AddSeconds($TtlSeconds)
    return [pscustomobject]@{
        run_id       = $RunId
        held_by      = $HeldBy
        pid          = $PID
        started_utc  = $startedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        expires_utc  = $expiresUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        ttl_seconds  = $TtlSeconds
    }
}

if (Test-Path ${leasePath}) {
    ${existing} = $null
    try { ${existing} = Get-Content ${leasePath} -Raw -ErrorAction Stop | ConvertFrom-Json }
    catch {
        Write-Warning "LEASE_CORRUPT path=${leasePath} err=$($_.Exception.Message) -- overwriting"
    }
    if (${existing}) {
        ${expiresUtc} = $null
        try { ${expiresUtc} = [datetime]::Parse(${existing}.expires_utc).ToUniversalTime() } catch {}
        ${pidAlive} = $false
        if (${existing}.PSObject.Properties.Name -contains 'pid' -and ${existing}.pid) {
            ${pidAlive} = [bool](Get-Process -Id ${existing}.pid -ErrorAction SilentlyContinue)
        }
        ${nowUtc} = (Get-Date).ToUniversalTime()
        if (${expiresUtc} -and ${nowUtc} -lt ${expiresUtc} -and ${pidAlive}) {
            throw "LEASE_HELD run_id=$(${existing}.run_id) held_by=$(${existing}.held_by) pid=$(${existing}.pid) expires=$(${existing}.expires_utc)"
        }
        Write-Warning "LEASE_STALE_TAKEOVER prior_run=$(${existing}.run_id) prior_pid=$(${existing}.pid) prior_expires=$(${existing}.expires_utc)"
    }
}

${leaseObj} = New-LeaseObject -RunId ${RunId} -HeldBy ${HeldBy} -TtlSeconds ${LeaseTtlSeconds}
Write-MastStatusFileAtomic -Path ${leasePath} -Object ${leaseObj}

# No in-process renewer: the TTL above is sized to cover worst-case
# provisioning. An in-process Timers.Timer + Register-ObjectEvent renewer
# was tried previously, but PSEventJob teardown at script exit hung
# powershell.exe under WinRM (clean exits stopped reaching the WinRM
# caller). If the TTL ever proves too short, run the renewer out of
# process instead -- do not reintroduce Register-ObjectEvent here.

function Write-Log {
    param([string]${Message})
    Write-MastLog -Message ${Message} -LogFile ${logFile}
}

# Hold the desired process exit code in a script-scope variable. We do NOT
# call `exit` from inside the try/catch below, because under WinRM that path
# regularly hangs powershell.exe at runspace teardown for many minutes
# (PSEventJob teardown, module Remove handlers, child-runspace draining --
# see CLAUDE.md). At the bottom of the file, after `finally` has released
# the lease, we call [Environment]::Exit($script:exitCode) to terminate
# the worker process immediately and unblock the host's WinRM read.
$script:exitCode = 1

try {
    Write-Log "=========================================="
    Write-Log "Starting MAST provisioning execution"
    Write-Log "=========================================="
    Write-Log "Staging path: ${StagingPath}"
    Write-Log "Hostname: ${env:COMPUTERNAME}"
    Write-Log "LEASE_ACQUIRE run_id=${RunId} held_by=${HeldBy} pid=$PID ttl_s=${LeaseTtlSeconds} expires=$(${leaseObj}.expires_utc)"

    # ---------------------------------------------------------------
    # Map Z: -> \\<ProvServer>\mast-shared (writable shared directory)
    # Persistent so the mapping survives reboots.
    # Skip if ProvServer was not passed or if Z: is already in use.
    # ---------------------------------------------------------------
    if (-not [string]::IsNullOrWhiteSpace(${ProvServer})) {
        ${sharedUNC} = "\\${ProvServer}\mast-shared"
        ${zDrive} = Get-PSDrive -Name 'Z' -ErrorAction SilentlyContinue
        if (${zDrive}) {
            Write-Log "Z: drive already mapped (root: $($zDrive.Root)) -- skipping mast-shared mapping."
        } else {
            Write-Log "Mapping Z: -> ${sharedUNC} (persistent)"
            ${netArgs} = @('use', 'Z:', ${sharedUNC})
            if (-not [string]::IsNullOrWhiteSpace(${SmbUser})) {
                ${netArgs} += ${SmbPass}
                ${netArgs} += "/user:${SmbUser}"
            }
            ${netArgs} += '/persistent:yes'
            ${netOut} = & net @netArgs 2>&1
            ${netRc}  = $LASTEXITCODE
            if (${netRc} -eq 0) {
                Write-Log "Z: mapped OK (persistent)."

                # Verify the share is writable.
                ${testFile} = "Z:\mast-write-test-${env:COMPUTERNAME}.tmp"
                try {
                    [System.IO.File]::WriteAllText(${testFile}, "write-test")
                    Remove-Item -Force ${testFile} -ErrorAction SilentlyContinue
                    Write-Log "Z: write verification: OK"
                } catch {
                    Write-Log "[WARN] Z: write verification failed: $($_.Exception.Message)"
                }
            } else {
                Write-Log "[WARN] Z: mapping failed (rc=${netRc}): $(($netOut | Out-String).Trim()) -- continuing without shared drive."
            }
        }
    }

    # Verify staging path exists
    if (-not (Test-Path ${StagingPath})) {
        throw "Staging path not found: ${StagingPath}"
    }

    # Import provisioning module
    ${provModulePath} = Join-Path ${StagingPath} "provisioning.psm1"
    if (-not (Test-Path ${provModulePath})) {
        Write-Log "WARNING: provisioning.psm1 not found at ${provModulePath}"
    } else {
        Import-Module ${provModulePath} -Force -DisableNameChecking
        Write-Log "Imported provisioning module"
    }

    # Read commands.json
    ${commandsJsonPath} = Join-Path ${StagingPath} "commands.json"
    if (-not (Test-Path ${commandsJsonPath})) {
        throw "Missing commands.json at ${commandsJsonPath}"
    }

    ${commands} = Import-MastCommandsFromJson -CommandsJsonPath ${commandsJsonPath}
    Write-Log "Loaded $(@(${commands}).Count) commands from commands.json"

    if (-not [string]::IsNullOrWhiteSpace(${Modules})) {
        ${moduleFilter} = @(${Modules}.Split(',') | Where-Object { $_ -ne '' })
        ${commands} = @(${commands} | Where-Object {
            ${m} = $_.module
            ${base} = if (${m} -like '*-verify') { ${m}.Substring(0, ${m}.Length - 7) } else { ${m} }
            ${moduleFilter} -contains ${base}
        })
        Write-Log "Module filter: $($moduleFilter -join ', '). Running $(@(${commands}).Count) command(s)."
    }

    # Execute commands in order
    ${successCount} = 0
    ${failCount} = 0
    ${commandCount} = @(${commands}).Count

    foreach (${cmd} in ${commands}) {
        Write-Log ""
        Write-Log "=========================================="
        Write-Log "[Order: $($cmd.order)] $($cmd.desc)"
        Write-Log "Module: $($cmd.module)"
        Write-Log "=========================================="

        try {
            # Change to staging directory for relative paths
            Push-Location ${StagingPath}

            Write-Log "Executing: $($cmd.cmd)"

            # Avoid cmd.exe /c: its line limit (~8191) can fail long powershell.exe lines.
            ${pr} = Invoke-MastChildCommandLine -CommandLine ${cmd}.cmd
            ${output} = ${pr}.Output
            ${exitCode} = ${pr}.ExitCode

            # Log output
            if (${output}) {
                ${output} | Tee-Object -FilePath ${logFile} -Append | Out-Null
            }

            if ($null -eq ${exitCode}) {
                Write-Log "[FAIL] $($cmd.module) (missing exit code after child process)"
                ${failCount}++
            }
            elseif (${exitCode} -eq 0) {
                Write-Log "SUCCESS: $($cmd.module) (exit code: ${exitCode})"
                ${successCount}++

                # Fallback smoke marker: write the literal "success" only if
                # the smoke file is missing or whitespace-only. Providers
                # that write rich structured smoke from the provider script
                # (e.g. proxy: 'proxy_ok mode=direct ie_enable=0 ...') keep
                # their content; modules without a verify still get a marker.
                # See DECISIONS.md 2026-05-26 for the full reasoning.
                ${smokeTestFile} = Join-Path ${smokeDir} "$($cmd.module)-smoke.txt"
                ${existingBody} = $null
                if (Test-Path -LiteralPath ${smokeTestFile}) {
                    try { ${existingBody} = Get-Content -LiteralPath ${smokeTestFile} -Raw -ErrorAction Stop } catch {}
                }
                if ([string]::IsNullOrWhiteSpace(${existingBody})) {
                    Set-Content -Path ${smokeTestFile} -Value "success" -Force
                }
            }
            else {
                Write-Log "[FAIL] $($cmd.module) (exit code: ${exitCode})"
                ${failCount}++
            }

            Pop-Location
        }
        catch {
            Write-Log "[FAIL] EXCEPTION in $($cmd.module): $_"
            ${failCount}++
            Pop-Location
        }
    }

    Write-Log ""
    Write-Log "=========================================="
    Write-Log "Provisioning Summary"
    Write-Log "=========================================="
    Write-Log "Total commands: ${commandCount}"
    Write-Log "Successful: ${successCount}"
    Write-Log "Failed: ${failCount}"
    Write-Log "=========================================="

    if (${failCount} -gt 0) {
        Write-Log "[WARN] Provisioning completed with ${failCount} failures"
        $script:exitCode = 1
    } else {
        # ---------------------------------------------------------------
        # Record the installed payload fingerprint so check-and-provision.ps1
        # can detect drift on the next autonomous cycle.
        # Only written on a fully-clean run (failCount == 0).
        # ---------------------------------------------------------------
        ${buildManifest}     = Join-Path ${StagingPath} "build-manifest.json"
        ${installedManifest} = Join-Path ${mastRoot} "installed-manifest.json"
        if (Test-Path ${buildManifest}) {
            try {
                ${m} = Get-Content ${buildManifest} -Raw | ConvertFrom-Json
                ${m} | Add-Member -NotePropertyName installed_at `
                                  -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -Force
                # Atomic write: tmp then rename, so a concurrent reader never
                # sees a partial file.
                ${tmp} = "${installedManifest}.tmp"
                (${m} | ConvertTo-Json -Depth 4) | Out-File -FilePath ${tmp} -Encoding UTF8
                Move-Item -Force ${tmp} ${installedManifest}
                Write-Log "Wrote installed-manifest.json (payload_hash=$($m.payload_hash))"
            } catch {
                Write-Log "WARNING: Failed to write installed-manifest.json: $_"
            }
        } else {
            Write-Log "WARNING: build-manifest.json not found in staging; skipping installed-manifest.json"
        }

        Write-Log "MAST provisioning completed successfully!"
        $script:exitCode = 0
    }
}
catch {
    ${errorMsg} = "Provisioning execution failed: $_"
    Write-Log ${errorMsg}
    Write-Error ${errorMsg}
    $script:exitCode = 1
}
finally {
    Write-Log "Log file: ${logFile}"

    # Release the lease, but only if we still own it -- a takeover may have
    # already overwritten it while we ran.
    try {
        if (Test-Path ${leasePath}) {
            ${current} = $null
            try { ${current} = Get-Content ${leasePath} -Raw -ErrorAction Stop | ConvertFrom-Json } catch {}
            if (${current} -and ${current}.run_id -eq ${RunId}) {
                Remove-Item -Force ${leasePath} -ErrorAction SilentlyContinue
                Write-Log "LEASE_RELEASE run_id=${RunId}"
            } elseif (${current}) {
                Write-Log "LEASE_RELEASE_SKIPPED run_id=${RunId} current_owner=$(${current}.run_id)"
            } else {
                Remove-Item -Force ${leasePath} -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Remove-Item -Force ${leasePath} -ErrorAction SilentlyContinue
    }

    # Reboot handling. The 'reboot' provider drops this flag at the end of the
    # run if Windows reports a pending reboot. We honor it only on a clean run
    # (exitCode == 0) and only when the caller passed -AllowReboot, so manual
    # operators are not surprised by an unattended restart. The flag is
    # consumed (deleted) before issuing the shutdown so a re-entry after the
    # reboot does not see stale state. See compare-mastw/GAPS.md "Reboot
    # handling after provisioning" and the REBOOT ME pattern at line 175.
    try {
        ${rebootFlag} = Join-Path ${mastRoot} 'state\reboot-requested.flag'
        if ((Test-Path ${rebootFlag}) -and $script:exitCode -eq 0) {
            if (${AllowReboot}) {
                Write-Log ("REBOOT_SCHEDULE flag={0} -AllowReboot=true; issuing shutdown /r /t 60" -f ${rebootFlag})
                Remove-Item -Force ${rebootFlag} -ErrorAction SilentlyContinue
                & shutdown.exe /r /t 60 /c "MAST provisioning reboot (pending changes detected)" | Out-Null
            } else {
                Write-Log ("REBOOT_DEFERRED flag={0} -AllowReboot not set; next autonomous cycle will reboot." -f ${rebootFlag})
            }
        }
    } catch {
        Write-Log ("REBOOT_HANDLER_ERROR " + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# Teardown breadcrumbs.
#
# History: a prior incarnation of this script used `[Environment]::Exit($code)`
# here to bypass PS runspace teardown, because a Register-ObjectEvent lease
# renewer was hanging powershell.exe for many minutes at exit. That renewer is
# long gone (see CLAUDE.md / DECISIONS.md), but the hard exit was left in
# place "just in case" -- and on the 2026-05-17 ASCOM-only run it produced a
# new failure mode: the wsmprovhost worker is terminated mid-shell, the WinRM
# SOAP "CommandState=Done" + ExitCode response never gets sent to the host,
# and the host's run_ps Invoke sits in Receive loops indefinitely (verified
# by handle dump: wsmprovhost gone from unit, host still ticking).
#
# Reverting to a clean `exit`. If the original Register-ObjectEvent-style
# teardown hang ever returns, the breadcrumbs below pinpoint which teardown
# stage stalls (each line is flushed to disk before the next stage begins, so
# the host-side log poller sees them even after WinRM stops responding).
#
# Do NOT bring back [Environment]::Exit without first confirming via these
# breadcrumbs that PS teardown is actually hanging; otherwise you trade a
# benign clean-exit delay for an unrecoverable host-side WinRM stall.
# [Environment]::Exit($script:exitCode)   # disabled 2026-05-17, see above
# ---------------------------------------------------------------------------
function Write-TeardownBreadcrumb {
    param([string]${Stage})
    try {
        ${ts} = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        ${line} = "${ts} | TEARDOWN ${Stage} pid=$PID"
        Add-Content -LiteralPath ${logFile} -Value ${line} -ErrorAction SilentlyContinue
    } catch {}
}

Write-TeardownBreadcrumb -Stage 'reached_exit_point'

# Enumerate anything that could plausibly stall runspace teardown so the next
# hang has named suspects in the log instead of a silent stall.
try {
    ${evtSubs} = @(Get-EventSubscriber -ErrorAction SilentlyContinue)
    ${psJobs}  = @(Get-Job -ErrorAction SilentlyContinue)
    Write-TeardownBreadcrumb -Stage ("inventory event_subscribers=" + ${evtSubs}.Count + " ps_jobs=" + ${psJobs}.Count)
    foreach (${es} in ${evtSubs}) {
        Write-TeardownBreadcrumb -Stage ("event_subscriber name=" + ${es}.SourceIdentifier + " source=" + ${es}.SourceObject)
    }
    foreach (${j} in ${psJobs}) {
        Write-TeardownBreadcrumb -Stage ("ps_job id=" + ${j}.Id + " name=" + ${j}.Name + " state=" + ${j}.State)
    }
} catch {
    Write-TeardownBreadcrumb -Stage ("inventory_failed " + $_.Exception.Message)
}

Write-TeardownBreadcrumb -Stage ("exit_code=" + $script:exitCode)
exit $script:exitCode
