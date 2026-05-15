#requires -Version 5.1
<#
.SYNOPSIS
  Run only *-verify commands from staging commands.json (no installers).

.DESCRIPTION
  Use after copying a fresh 01-provisioning payload to the unit (same layout as
  execute-mast-provisioning.ps1). Does not take the full provisioning execute.lock.

  How to stage and run verify-only on a unit:

  1) On the build host (from MAST_provisioning repo root, admin PowerShell):

       .\build\build-mast.ps1 -HostName mast01 [-TestMode]

     This writes staging\mast01\01-provisioning\ with commands.json, verify scripts,
     mast-log.ps1, provisioning.psm1, run-verify-only.ps1, etc.

  2) Copy that 01-provisioning folder to the unit, e.g. to C:\mast-staging (merge /
     replace so commands.json and verify-*.ps1 are current).

  3) On the unit, from an elevated PowerShell:

       Set-Location C:\mast-staging
       powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive `
         -File .\run-verify-only.ps1 -StagingPath .

  Exit code 0 if every verify step returned 0; otherwise 1.

.PARAMETER StagingPath
  Directory containing commands.json (typically C:\mast-staging after WinRM copy).

.PARAMETER Modules
  Comma-separated module names to verify (e.g. 'git,python'). Empty = all verify commands.
#>
[CmdletBinding()]
param(
    [string]${StagingPath} = '.',
    [string]${Modules}     = ''  # comma-separated; empty = all verify commands
)

${ErrorActionPreference} = 'Stop'

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path -LiteralPath ${mastLogDot})) {
    ${mastLogDot} = Join-Path ${PSScriptRoot} '..\server\lib\mast-log.ps1'
}
if (-not (Test-Path -LiteralPath ${mastLogDot})) {
    throw "mast-log.ps1 not found next to this script or under server\lib."
}
. ${mastLogDot}

${invokeDot} = Join-Path ${PSScriptRoot} 'mast-invoke-child.ps1'
if (-not (Test-Path -LiteralPath ${invokeDot})) {
    ${invokeDot} = Join-Path ${PSScriptRoot} '..\client\mast-invoke-child.ps1'
}
if (-not (Test-Path -LiteralPath ${invokeDot})) {
    throw "mast-invoke-child.ps1 not found next to this script or under client."
}
. ${invokeDot}

${logDir} = Get-MastLogSessionDir
${null} = New-Item -ItemType Directory -Path ${logDir} -Force -ErrorAction SilentlyContinue
${logFile} = Join-Path ${logDir} 'provisioning-verify-only.log'

function Write-VerifyLog {
    param([string]${Message})
    Write-MastLog -Message ${Message} -LogFile ${logFile}
}

${stagingResolved} = (Resolve-Path -LiteralPath ${StagingPath}).Path
Write-VerifyLog "=========================================="
Write-VerifyLog "MAST verify-only (staging=${stagingResolved})"
Write-VerifyLog "=========================================="

${commandsJsonPath} = Join-Path ${stagingResolved} 'commands.json'
if (-not (Test-Path -LiteralPath ${commandsJsonPath})) {
    throw "Missing commands.json at ${commandsJsonPath}"
}

${commands} = Import-MastCommandsFromJson -CommandsJsonPath ${commandsJsonPath}
# Normalize JSON numeric quirks (some deserializers yield array or double for "order").
${verifyCmds} = @(
    ${commands} |
        Where-Object { $PSItem.module -like '*-verify' } |
        Sort-Object -Property {
            ${raw} = @( $_.order )[0]
            if ($null -eq ${raw}) {
                return 0
            }
            try {
                return [int]${raw}
            }
            catch {
                return 0
            }
        }
)
if (${verifyCmds}.Count -lt 1) {
    throw 'No *-verify commands found in commands.json'
}

if (-not [string]::IsNullOrWhiteSpace(${Modules})) {
    ${moduleFilter} = @(${Modules}.Split(',') | Where-Object { $_ -ne '' })
    ${verifyCmds} = @(${verifyCmds} | Where-Object {
        ${base} = $_.module -replace '-verify$', ''
        ${moduleFilter} -contains ${base}
    })
    Write-VerifyLog ("Module filter: {0}. Running {1} verify command(s)." -f ($moduleFilter -join ', '), ${verifyCmds}.Count)
}

Write-VerifyLog ("Found {0} verify command(s)." -f ${verifyCmds}.Count)

${failCount} = 0
foreach (${cmd} in ${verifyCmds}) {
    Write-VerifyLog ''
    Write-VerifyLog "=========================================="
    Write-VerifyLog ("[Order: {0}] {1}" -f ${cmd}.order, ${cmd}.desc)
    Write-VerifyLog ("Module: {0}" -f ${cmd}.module)
    Write-VerifyLog "=========================================="
    Push-Location -LiteralPath ${stagingResolved}
    try {
        Write-VerifyLog ("Executing: {0}" -f ${cmd}.cmd)
        ${pr} = Invoke-MastChildCommandLine -CommandLine ${cmd}.cmd
        if (${pr}.Output) {
            ${pr}.Output | Tee-Object -FilePath ${logFile} -Append
        }
        ${exitCode} = ${pr}.ExitCode
        if ($null -eq ${exitCode}) {
            Write-VerifyLog ("[FAIL] {0} (missing exit code after child process)" -f ${cmd}.module)
            ${failCount}++
        }
        elseif (${exitCode} -eq 0) {
            Write-VerifyLog ("SUCCESS: {0} (exit code: 0)" -f ${cmd}.module)
        }
        else {
            Write-VerifyLog ("[FAIL] {0} (exit code: {1})" -f ${cmd}.module, ${exitCode})
            ${failCount}++
        }
    }
    catch {
        Write-VerifyLog ("[FAIL] EXCEPTION in {0}: {1}" -f ${cmd}.module, $_.Exception.Message)
        ${failCount}++
    }
    finally {
        Pop-Location
    }
}

Write-VerifyLog ''
Write-VerifyLog "=========================================="
Write-VerifyLog "Verify-only summary: failures=${failCount}"
Write-VerifyLog ("Log file: {0}" -f ${logFile})
Write-VerifyLog "=========================================="
if (${failCount} -gt 0) {
    exit 1
}
exit 0
