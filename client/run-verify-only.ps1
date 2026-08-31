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

.PARAMETER ReportPath
  Where to write the machine-readable per-module result. This is the tier-2
  COMPUTED state for per-module tracking (#22 stage 4): the written
  installed-manifest says what was installed, this says what is actually working
  right now, so a module whose hash still matches but whose service has stopped
  classifies as needs-repair instead of up-to-date. Pass '' to skip the write.
#>
[CmdletBinding()]
param(
    [string]${StagingPath} = '.',
    [string]${Modules}     = '',  # comma-separated; empty = all verify commands
    [string]${ReportPath}  = ''   # default resolved below, once mast-log.ps1 is loaded
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

# Default beside the other unit state (installed-manifest.json, status\).
if ($null -eq ${ReportPath}) { ${ReportPath} = '' }
if (${ReportPath} -eq '') {
    ${ReportPath} = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'status\validation.json'
}

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

# module -> 'pass' | 'fail' | 'unverifiable'. Ordered so the report reads in
# execution order.
#
# 'unverifiable' (child exit 2) is a THIRD state, not a severity between the other
# two: every check that could run passed and at least one could not, typically
# because the unit cannot reach origin. Folding it into 'pass' is what let a stale
# checkout read as current (#177); folding it into 'fail' would put a unit in the
# red for a network condition and make an operator's local run useless. It does not
# count toward ${failCount}, so this script's own exit code is unchanged -- the
# distinction is carried in the report, for the fleet view that needs it.
${MastVerifyUnverifiableExit} = 2
${failCount} = 0
${unverifiableCount} = 0
${moduleResults} = [ordered]@{}
foreach (${cmd} in ${verifyCmds}) {
    ${moduleName} = ${cmd}.module -replace '-verify$', ''
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
            ${moduleResults}[${moduleName}] = 'fail'
        }
        elseif (${exitCode} -eq 0) {
            Write-VerifyLog ("SUCCESS: {0} (exit code: 0)" -f ${cmd}.module)
            if (-not ${moduleResults}.Contains(${moduleName})) { ${moduleResults}[${moduleName}] = 'pass' }
        }
        elseif (${exitCode} -eq ${MastVerifyUnverifiableExit}) {
            Write-VerifyLog ("UNVERIFIABLE: {0} (exit code: {1}) -- checks passed, at least one could not be run" -f ${cmd}.module, ${exitCode})
            ${unverifiableCount}++
            # Never over a 'fail' from another command of the same module: a
            # concrete problem outranks an unanswered question.
            if (${moduleResults}[${moduleName}] -ne 'fail') { ${moduleResults}[${moduleName}] = 'unverifiable' }
        }
        else {
            Write-VerifyLog ("[FAIL] {0} (exit code: {1})" -f ${cmd}.module, ${exitCode})
            ${failCount}++
            ${moduleResults}[${moduleName}] = 'fail'
        }
    }
    catch {
        Write-VerifyLog ("[FAIL] EXCEPTION in {0}: {1}" -f ${cmd}.module, $_.Exception.Message)
        ${failCount}++
        ${moduleResults}[${moduleName}] = 'fail'
    }
    finally {
        Pop-Location
    }
}

# Machine-readable result for the driver / fleet report. Atomic write (tmp then
# rename) for the same reason installed-manifest.json uses one: a reader must
# never see half a document.
if (${ReportPath}) {
    try {
        ${reportDir} = Split-Path -Parent ${ReportPath}
        if (${reportDir}) { ${null} = New-Item -ItemType Directory -Path ${reportDir} -Force -ErrorAction SilentlyContinue }
        ${report} = [pscustomobject][ordered]@{
            checked_at    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            failures      = ${failCount}
            unverifiable  = ${unverifiableCount}
            modules       = ${moduleResults}
        }
        ${reportTmp} = "${ReportPath}.tmp"
        (${report} | ConvertTo-Json -Depth 4) | Out-File -FilePath ${reportTmp} -Encoding UTF8
        Move-Item -Force ${reportTmp} ${ReportPath}
        Write-VerifyLog ("Wrote validation report: {0}" -f ${ReportPath})
    }
    catch {
        # A missing report degrades tier-2 to "unknown" (the driver then trusts
        # the written manifest); it must not fail the verify run itself.
        Write-VerifyLog ("WARNING: could not write validation report: {0}" -f $_.Exception.Message)
    }
}

Write-VerifyLog ''
Write-VerifyLog "=========================================="
Write-VerifyLog "Verify-only summary: failures=${failCount} unverifiable=${unverifiableCount}"
Write-VerifyLog ("Log file: {0}" -f ${logFile})
Write-VerifyLog "=========================================="
# Hard exit to bypass PS runspace teardown under WinRM (see the matching
# block at the bottom of execute-mast-provisioning.ps1 for full rationale).
# This script imports/dot-sources the same modules as execute and runs
# the same per-module child commands, so the same hang risk applies.
if (${failCount} -gt 0) {
    [Environment]::Exit(1)
}
[Environment]::Exit(0)
