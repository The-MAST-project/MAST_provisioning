#requires -Version 5.1
<#
.SYNOPSIS
  Converge this unit on the current bootstrap by re-asserting what may be re-asserted.

.DESCRIPTION
  Runs client\bootstrap.ps1 -ReassertOnly, staged next to this script as a
  'repofiles' entry. That mode applies only the elements the registry marks
  'routine': it never prompts, never reboots, and never touches the first-touch
  work (account, autologon, rename, Npcap, the hardware preflight).

  WHY THIS PROVIDER EXISTS: bringing a fleet unit up to a newer bootstrap used
  to mean walking to it with a USB stick, even though a provisioning run already
  reaches every unit and already knows which elements it is missing
  (MAST_provisioning#143). The payload was always the delivery mechanism; what
  was missing was a mode of bootstrap that is safe to re-run.

  It runs on EVERY cycle rather than only when a unit is behind. The elements
  are idempotent registry writes and service checks, and the alternative --
  running only when the stamped bootstrap_version is below current -- does
  nothing for a unit whose version is null because it predates stamping. That is
  not hypothetical: it is mast02, the named target of #143.
#>
[CmdletBinding()]
param(
    # Bound the child so a wedged element cannot hold the whole provisioning run.
    [int]${TimeoutMinutes} = 20
)

${ErrorActionPreference} = 'Stop'

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}

${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} 'bootstrap-reassert-install.log'

function Write-ReassertLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 `
    -Value ("[{0}] provide-bootstrap-reassert.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    ${bootstrap} = Join-Path ${PSScriptRoot} 'bootstrap.ps1'
    if (-not (Test-Path -LiteralPath ${bootstrap})) {
        throw ("bootstrap.ps1 not found at {0}. It is staged as a 'repofiles' entry of this module; see build-mast.ps1." -f ${bootstrap})
    }

    Write-ReassertLog ("Running bootstrap.ps1 -ReassertOnly (timeout {0} min)..." -f ${TimeoutMinutes})

    # System.Diagnostics.Process, NOT Start-Process: under the WinRM host on
    # PowerShell 5.1 the cmdlet's -PassThru object loses the exit code of a
    # short-lived redirected process, which is how provide-jupyter came to fail
    # on successful runs. Async ReadToEnd on both pipes avoids the classic
    # redirected-pipe deadlock. Out-of-process rather than '&' so a stray exit
    # or a wedged element cannot take this provider down with it.
    ${psi} = New-Object System.Diagnostics.ProcessStartInfo
    ${psi}.FileName = (Join-Path ${env:SystemRoot} 'System32\WindowsPowerShell\v1.0\powershell.exe')
    ${psi}.Arguments = ('-ExecutionPolicy Bypass -NoProfile -NonInteractive -File "{0}" -ReassertOnly' -f ${bootstrap})
    ${psi}.UseShellExecute = $false
    ${psi}.RedirectStandardOutput = $true
    ${psi}.RedirectStandardError = $true
    ${psi}.CreateNoWindow = $true

    ${proc} = [System.Diagnostics.Process]::Start(${psi})
    if (-not ${proc}) { throw 'Process start returned no object for bootstrap -ReassertOnly' }
    ${stdoutTask} = ${proc}.StandardOutput.ReadToEndAsync()
    ${stderrTask} = ${proc}.StandardError.ReadToEndAsync()
    ${timedOut} = -not ${proc}.WaitForExit(${TimeoutMinutes} * 60 * 1000)
    if (${timedOut}) {
        try { & taskkill.exe /T /F /PID $(${proc}.Id) 2>$null | Out-Null } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
        try { ${proc}.Kill() } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
    } else {
        ${proc}.WaitForExit()   # drain the async readers before touching ExitCode
    }

    ${childLog} = Join-Path ${logDir} 'bootstrap-reassert-run.log'
    try { Set-Content -LiteralPath ${childLog} -Encoding UTF8 -Value ${stdoutTask}.Result } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
    try { Set-Content -LiteralPath ("{0}.err" -f ${childLog}) -Encoding UTF8 -Value ${stderrTask}.Result } catch { Write-Verbose "ignored: $($_.Exception.Message)" }

    if (${timedOut}) {
        throw ("bootstrap -ReassertOnly timed out after {0} min; process tree killed. See {1}" -f ${TimeoutMinutes}, ${childLog})
    }

    ${code} = ${proc}.ExitCode
    if ($null -eq ${code}) { throw ("bootstrap -ReassertOnly reported no exit code; see {0}" -f ${childLog}) }

    # Echo the child's own summary lines so the provisioning log tells the story
    # without a reader having to open a second file.
    foreach (${line} in (${stdoutTask}.Result -split "`r?`n")) {
        if (${line} -match 'Applying |applied: |FAILED |\[OK\] Re-assert|\[FAIL\]|Recorded the re-assert') {
            Write-ReassertLog ('  ' + ${line}.Trim())
        }
    }
    Write-ReassertLog ("bootstrap -ReassertOnly exit={0} (log {1})" -f ${code}, ${childLog})

    ${smoke} = Get-MastSmokeMarker -Module 'bootstrap-reassert'
    New-Item -ItemType Directory -Path (Split-Path -Parent ${smoke}) -Force | Out-Null
    Set-Content -LiteralPath ${smoke} -Encoding UTF8 -Value ("reassert_exit={0}" -f ${code})

    if (${code} -ne 0) {
        throw ("bootstrap -ReassertOnly failed (exit {0}); see {1}" -f ${code}, ${childLog})
    }

    Write-ReassertLog 'bootstrap-reassert completed successfully'
    exit 0
}
catch {
    ${msg} = "bootstrap-reassert failed: $_"
    Write-Host ${msg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${msg}
    exit 1
}
