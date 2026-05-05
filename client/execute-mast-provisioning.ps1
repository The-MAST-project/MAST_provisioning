[CmdletBinding()]
param(
    [string]${StagingPath} = "."
)

${ErrorActionPreference} = "Stop"
${logDir} = Join-Path ${env:ProgramData} "MAST\logs"
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "provisioning-execute.log"

function Write-Log {
    param([string]${Message})
    ${timestamp} = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "${timestamp} | ${Message}" | Tee-Object -FilePath ${logFile} -Append
}

try {
    Write-Log "=========================================="
    Write-Log "Starting MAST provisioning execution"
    Write-Log "=========================================="
    Write-Log "Staging path: ${StagingPath}"
    Write-Log "Hostname: ${env:COMPUTERNAME}"

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

    ${commands} = Get-Content ${commandsJsonPath} -Raw | ConvertFrom-Json
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

            # Execute command and capture output
            ${output} = Invoke-Expression ${cmd}.cmd 2>&1
            ${exitCode} = ${LASTEXITCODE}

            # Log output
            if (${output}) {
                ${output} | Tee-Object -FilePath ${logFile} -Append | Out-Null
            }

            if (${exitCode} -eq 0) {
                Write-Log "SUCCESS: $($cmd.module) (exit code: ${exitCode})"
                ${successCount}++

                # Write smoke test file
                ${smokeTestFile} = Join-Path ${logDir} "$($cmd.module)-smoke.txt"
                Set-Content -Path ${smokeTestFile} -Value "success" -Force
            } else {
                Write-Log "✗ FAILED: $($cmd.module) (exit code: ${exitCode})"
                ${failCount}++
            }

            Pop-Location
        }
        catch {
            Write-Log "✗ EXCEPTION in $($cmd.module): $_"
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
        Write-Log "⚠ Provisioning completed with ${failCount} failures"
        exit 1
    } else {
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
}
