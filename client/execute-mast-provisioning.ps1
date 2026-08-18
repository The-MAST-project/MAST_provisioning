[CmdletBinding()]
param(
    [string]${StagingPath}       = ".",
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

${installedManifestDot} = Join-Path ${PSScriptRoot} 'mast-installed-manifest.ps1'
if (-not (Test-Path ${installedManifestDot})) {
    ${installedManifestDot} = Join-Path ${PSScriptRoot} '..\client\mast-installed-manifest.ps1'
}
if (-not (Test-Path ${installedManifestDot})) {
    throw "mast-installed-manifest.ps1 not found (expected next to this script or under client)."
}
. ${installedManifestDot}

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
${null} = Get-MastVerifyDir
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
# Exit codes. 0 = every command succeeded, 1 = at least one module failed.
# Anything else is a distinct, documented refusal that is NOT a failure -- a
# caller must be able to tell "I declined to run" from "the run went wrong",
# because the correct reaction differs (attach or skip, vs reprovision).
# ---------------------------------------------------------------------------
Set-Variable -Name MAST_EXIT_LEASE_HELD -Value 10 -Option Constant -Scope Script

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
            # A refusal is not a failure, and must not look like one. This used to be a
            # plain `throw`: exit 1, identical to a genuine provisioning failure, with the
            # message naming the holder on stderr where nothing surfaced it. A live run
            # was consequently misdiagnosed as dead and an issue filed claiming no lease
            # guard existed, when the guard had worked perfectly (#47).
            #
            # Exit ${MAST_EXIT_LEASE_HELD} says "a run is already in progress" so a caller
            # can attach or skip rather than reprovisioning over a healthy run -- the
            # reaction the autonomous loop would otherwise get wrong. Emitted on STDOUT as
            # well, so a caller reading only stdout still learns which run holds it.
            ${heldMsg} = "LEASE_HELD run_id=$(${existing}.run_id) held_by=$(${existing}.held_by) pid=$(${existing}.pid) expires=$(${existing}.expires_utc)"
            Write-Output ${heldMsg}
            Write-Warning ${heldMsg}
            # Leave no empty session dir behind to explain later: this run did nothing.
            if ((Test-Path -LiteralPath ${logDir}) -and
                -not (Get-ChildItem -LiteralPath ${logDir} -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath ${logDir} -Force -Recurse -ErrorAction SilentlyContinue
            }
            exit ${MAST_EXIT_LEASE_HELD}
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

    # Execute does NOT map Z:. It used to map Z: -> \\<ProvServer>\mast-shared
    # persistently, which claimed a letter that belongs to the operational store
    # (\\<controller_host>\mast-share) and did so in a session the LocalSystem MAST
    # services cannot see. The mapping now belongs to the mast-shared-mount provider,
    # which establishes it in the SYSTEM session. See issue #25.

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
    # Per-module provide/verify outcomes for the cumulative installed-manifest.
    # Recorded for every command, pass or fail, so a partial run still says which
    # modules landed rather than leaving the whole record stale (issue #22).
    ${moduleOutcomes} = New-MastModuleOutcomeMap

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
                ${moduleOutcomes} = Add-MastModuleOutcome -Outcomes ${moduleOutcomes} `
                    -CommandModule ${cmd}.module -Success $false
            }
            elseif (${exitCode} -eq 0) {
                Write-Log "SUCCESS: $($cmd.module) (exit code: ${exitCode})"
                ${successCount}++
                ${moduleOutcomes} = Add-MastModuleOutcome -Outcomes ${moduleOutcomes} `
                    -CommandModule ${cmd}.module -Success $true

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
                ${moduleOutcomes} = Add-MastModuleOutcome -Outcomes ${moduleOutcomes} `
                    -CommandModule ${cmd}.module -Success $false
            }

            Pop-Location
        }
        catch {
            Write-Log "[FAIL] EXCEPTION in $($cmd.module): $_"
            ${failCount}++
            ${moduleOutcomes} = Add-MastModuleOutcome -Outcomes ${moduleOutcomes} `
                -CommandModule ${cmd}.module -Success $false
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

    # -------------------------------------------------------------------
    # Record what this run installed, per module, MERGED into whatever the
    # unit already had.
    #
    # Written on EVERY run, not only a clean one. The old code wrote the
    # manifest only when failCount was 0, so a run where one module failed
    # left the record describing a payload from days ago -- and the next
    # cycle could not tell which modules were actually current. Merging a
    # partial run keeps the record truthful: the modules that landed are
    # recorded as landed, the ones that failed are recorded as failed, and
    # the untouched ones keep their prior entry.
    #
    # fully_provisioned and the aggregate payload_hash are what protect the
    # autonomous loop: payload_hash is published only when every module the
    # build declares is present, hash-matched and clean, so a partial run
    # cannot make the fast path report "nothing to do".
    # See docs/per-module-tracking-plan.md Stage 2, issue #22.
    # -------------------------------------------------------------------
    ${buildManifest}     = Join-Path ${StagingPath} "build-manifest.json"
    ${installedManifest} = Join-Path ${mastRoot} "installed-manifest.json"
    if (Test-Path ${buildManifest}) {
        try {
            ${buildData} = Get-Content ${buildManifest} -Raw | ConvertFrom-Json

            ${previous} = $null
            if (Test-Path -LiteralPath ${installedManifest}) {
                try {
                    ${previous} = Get-Content ${installedManifest} -Raw | ConvertFrom-Json
                } catch {
                    # A corrupt prior manifest must not abort the run, but it
                    # must not be silently treated as "no modules installed"
                    # either -- that would read as a clean slate. Say so; the
                    # merge then starts from this run's coverage and Stage 3
                    # reprovisions whatever it cannot account for.
                    Write-Log "WARNING: existing installed-manifest.json unreadable, starting coverage from this run: $_"
                    ${previous} = $null
                }
            }

            # Upstream provenance, if mast-clone left it. Read here rather than in
            # the merge so the merge stays a pure function over its inputs, and so a
            # malformed sidecar degrades to "no repos key" instead of failing the run
            # -- the manifest write is the last thing standing between a good run and
            # a unit that cannot say what it installed.
            ${repos} = $null
            ${cloneManifest} = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'src\clone-manifest.json'
            if (Test-Path -LiteralPath ${cloneManifest}) {
                try {
                    ${cm} = Get-Content -LiteralPath ${cloneManifest} -Raw | ConvertFrom-Json
                    if (${cm}.PSObject.Properties.Match('repos').Count) { ${repos} = ${cm}.repos }
                }
                catch {
                    Write-Log "WARNING: clone-manifest.json unreadable, recording no upstream revisions: $_"
                }
            }

            ${merged} = Merge-MastInstalledManifest -Previous ${previous} -BuildData ${buildData} `
                -Outcomes ${moduleOutcomes} `
                -InstalledAt ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) `
                -Repos ${repos}

            # Atomic write: tmp then rename, so a concurrent reader never
            # sees a partial file.
            ${tmp} = "${installedManifest}.tmp"
            (${merged} | ConvertTo-Json -Depth 6) | Out-File -FilePath ${tmp} -Encoding UTF8
            Move-Item -Force ${tmp} ${installedManifest}
            Write-Log ("Wrote installed-manifest.json (modules touched={0}, fully_provisioned={1})" -f `
                @(${moduleOutcomes}.Keys).Count, ${merged}.fully_provisioned)
        } catch {
            Write-Log "WARNING: Failed to write installed-manifest.json: $_"
        }
    } else {
        Write-Log "WARNING: build-manifest.json not found in staging; skipping installed-manifest.json"
    }

    if (${failCount} -gt 0) {
        Write-Log "[WARN] Provisioning completed with ${failCount} failures"
        $script:exitCode = 1
    } else {
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
