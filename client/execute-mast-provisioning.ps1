[CmdletBinding()]
param(
    [string]${StagingPath}       = ".",
    [string]${ProvServer}        = "",
    [string]${SmbUser}           = "",
    [string]${SmbPass}           = "",
    [string]${Modules}           = "",  # comma-separated; empty = all modules
    [string]${RunId}             = "",  # autonomous: server passes its run id; manual: auto-generated
    [string]${HeldBy}            = "",  # hostname of orchestrator; defaults to local computer
    [int]   ${LeaseTtlSeconds}   = 7200  # 2 h default; comfortably covers a ~40 min provisioning run on a slow VM without an in-process renewer
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

${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${smokeDir} = Get-MastSmokeDir
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

                # Write smoke test file
                ${smokeTestFile} = Join-Path ${smokeDir} "$($cmd.module)-smoke.txt"
                Set-Content -Path ${smokeTestFile} -Value "success" -Force
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
        exit 1
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
        exit 0
    }
}
catch {
    ${errorMsg} = "Provisioning execution failed: $_"
    Write-Log ${errorMsg}
    Write-Error ${errorMsg}
    exit 1
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
}
