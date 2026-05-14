[CmdletBinding()]
param(
    [string]${StagingPath} = ".",
    [string]${ProvServer}  = "",
    [string]${SmbUser}     = "",
    [string]${SmbPass}     = ""
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

# State under <SystemDrive>\MAST (same tree as logs); avoid ProgramData for execute lock.
${mastRoot} = Join-Path ${env:SystemDrive} "MAST"
${null} = New-Item -ItemType Directory -Path ${mastRoot} -Force -ErrorAction SilentlyContinue

# Remove stale lock from previous layout (ProgramData) so a path change does not block forever.
${legacyLock} = Join-Path ${env:ProgramData} "MAST\execute.lock"
if (Test-Path ${legacyLock}) {
    try {
        Remove-Item -Force ${legacyLock} -ErrorAction Stop
    } catch {
        Write-Warning "Could not remove legacy lock at ${legacyLock}: $($_.Exception.Message)"
    }
}

# Prevent overlapping provisioning runs on the same unit.
${lockPath} = Join-Path ${mastRoot} "execute.lock"
if (Test-Path ${lockPath}) {
    ${lockInfo} = ''
    try { ${lockInfo} = (Get-Content ${lockPath} -Raw -ErrorAction SilentlyContinue).Trim() } catch {}
    if (${lockInfo}) {
        ${lockInfo} = (${lockInfo} -replace "`r`n", ' ' -replace "`n", ' ').Trim()
    }
    throw "Another provisioning run is in progress (lock: ${lockPath}). If no run is active, delete that file. Details: ${lockInfo}"
}
try {
    "pid=$PID`nstarted=$(Get-Date -Format s)`nstaging=${StagingPath}" | Out-File -FilePath ${lockPath} -Encoding UTF8 -Force
} catch {
    Write-Warning "Failed to create lock file at ${lockPath}: $($_.Exception.Message)"
}

function Write-Log {
    param([string]${Message})
    ${timestamp} = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "${timestamp} | ${Message}" | Tee-Object -FilePath ${logFile} -Append
}

# Track whether this run mapped Z: so the finally block only unmaps what we mapped.
${script:MappedSharedDrive} = $false

try {
    Write-Log "=========================================="
    Write-Log "Starting MAST provisioning execution"
    Write-Log "=========================================="
    Write-Log "Staging path: ${StagingPath}"
    Write-Log "Hostname: ${env:COMPUTERNAME}"

    # ---------------------------------------------------------------
    # Map Z: -> \\<ProvServer>\mast-shared (writable shared directory)
    # Skip if ProvServer was not passed or if Z: is already in use.
    # ---------------------------------------------------------------
    if (-not [string]::IsNullOrWhiteSpace(${ProvServer})) {
        ${sharedUNC} = "\\${ProvServer}\mast-shared"
        ${zDrive} = Get-PSDrive -Name 'Z' -ErrorAction SilentlyContinue
        if (${zDrive}) {
            Write-Log "Z: drive already mapped (root: $($zDrive.Root)) -- skipping mast-shared mapping."
        } else {
            Write-Log "Mapping Z: -> ${sharedUNC}"
            ${netArgs} = @('use', 'Z:', ${sharedUNC}, '/persistent:no')
            if (-not [string]::IsNullOrWhiteSpace(${SmbUser})) {
                ${netArgs} += ${SmbPass}
                ${netArgs} += "/user:${SmbUser}"
            }
            ${netOut} = & net @netArgs 2>&1
            ${netRc}  = $LASTEXITCODE
            if (${netRc} -eq 0) {
                ${script:MappedSharedDrive} = $true
                Write-Log "Z: mapped OK."

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
    if (${script:MappedSharedDrive}) {
        & net use Z: /delete /yes 2>&1 | Out-Null
        Write-Log "Z: unmapped."
    }
    Write-Log "Log file: ${logFile}"
    Remove-Item -Force ${lockPath} -ErrorAction SilentlyContinue
}
