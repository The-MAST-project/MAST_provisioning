#requires -Version 5.1
[CmdletBinding()]
param(
    [string]${PythonExe}   = 'C:\Python312\python.exe',
    [string]${JupyterRoot} = 'C:\MAST\jupyter',
    # Reinstall even if the venv/jupyter is already present.
    [switch]${Force}
)

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} 'jupyter-install.log'

function Write-JupyterLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

# Run a native exe (python/pip) with output captured to a per-step log and a bounded
# wait, so a stalled pip through the proxy cannot hang the whole run. -NoNewWindow so
# stdout/stderr can be redirected. Throws on non-zero exit.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]${Exe},
        [Parameter(Mandatory)][string[]]${NativeArgs},
        [Parameter(Mandatory)][string]${Tag},
        [int]${TimeoutMs} = (30 * 60 * 1000)
    )
    ${out} = Join-Path ${logDir} ("jupyter-{0}.log" -f ${Tag})
    # System.Diagnostics.Process directly, NOT Start-Process: in Windows
    # PowerShell 5.1 under the WinRM host, the cmdlet's -PassThru object loses
    # the exit code of short-lived redirected processes ("exit=" was empty for
    # SUCCESSFUL venv-create/pip runs, failing the provider). A manually
    # started Process reports ExitCode reliably after WaitForExit. Async
    # ReadToEnd on both pipes avoids the classic redirected-pipe deadlock.
    ${psi} = New-Object System.Diagnostics.ProcessStartInfo
    ${psi}.FileName = ${Exe}
    ${psi}.Arguments = ((${NativeArgs} | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' ')
    ${psi}.UseShellExecute = $false
    ${psi}.RedirectStandardOutput = $true
    ${psi}.RedirectStandardError = $true
    ${psi}.CreateNoWindow = $true
    ${proc} = [System.Diagnostics.Process]::Start(${psi})
    if (-not ${proc}) { throw ("Process start returned no object for {0}" -f ${Tag}) }
    ${stdoutTask} = ${proc}.StandardOutput.ReadToEndAsync()
    ${stderrTask} = ${proc}.StandardError.ReadToEndAsync()
    ${timedOut} = -not ${proc}.WaitForExit(${TimeoutMs})
    if (${timedOut}) {
        try { & taskkill.exe /T /F /PID $(${proc}.Id) 2>$null | Out-Null } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
        try { ${proc}.Kill() } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
    } else {
        ${proc}.WaitForExit()   # drain the async readers before touching ExitCode
    }
    try { Set-Content -LiteralPath ${out} -Encoding UTF8 -Value ${stdoutTask}.Result } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
    try { Set-Content -LiteralPath ("{0}.err" -f ${out}) -Encoding UTF8 -Value ${stderrTask}.Result } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
    if (${timedOut}) {
        throw ("{0} timed out; process tree killed. See {1}" -f ${Tag}, ${out})
    }
    ${code} = ${proc}.ExitCode
    Write-JupyterLog ("{0} exit={1} (log {2})" -f ${Tag}, ${code}, ${out})
    if ($null -eq ${code}) { throw ("{0} reported no exit code; see {1}" -f ${Tag}, ${out}) }
    if (${code} -ne 0) { throw ("{0} failed (exit {1}); see {2}" -f ${Tag}, ${code}, ${out}) }
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-jupyter.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    if (-not (Test-Path -LiteralPath ${PythonExe})) {
        throw "Python not found at ${PythonExe}; the python provider (order 600) must run first."
    }

    # Well-defined, contained layout under C:\MAST\jupyter.
    ${venv}   = Join-Path ${JupyterRoot} '.venv'
    ${venvPy} = Join-Path ${venv} 'Scripts\python.exe'
    ${jnExe}  = Join-Path ${venv} 'Scripts\jupyter-notebook.exe'
    New-Item -ItemType Directory -Path ${JupyterRoot} -Force | Out-Null
    foreach (${d} in 'data', 'config', 'runtime', 'notebooks') {
        New-Item -ItemType Directory -Path (Join-Path ${JupyterRoot} ${d}) -Force | Out-Null
    }

    # 1) Dedicated venv, created with the stdlib venv module: no install, no PyPI
    #    fetch, nothing vendored (#131).
    if (${Force} -and (Test-Path -LiteralPath ${venv})) {
        Write-JupyterLog "Force: removing existing venv."
        Remove-Item -LiteralPath ${venv} -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath ${venvPy})) {
        Write-JupyterLog ("Creating venv at {0}" -f ${venv})
        Invoke-Native -Exe ${PythonExe} -NativeArgs @('-m', 'venv', ${venv}) -Tag 'venv-create' -TimeoutMs (5 * 60 * 1000)
        if (-not (Test-Path -LiteralPath ${venvPy})) { throw ("Failed to create venv at {0}" -f ${venv}) }
    } else {
        Write-JupyterLog "venv already present; skipping creation."
    }

    # 2) Install the LOCKED Jupyter + scientific stack into the venv from
    #    assets\requirements.txt. Every unit gets the same 118 packages, so two
    #    units provisioned months apart run the same software -- mast05 and
    #    mast06, four days apart, had already diverged on scipy and two
    #    transitive packages (#133).
    # build-mast flattens assets/* to the staging root, beside this script.
    ${reqFile} = Join-Path ${PSScriptRoot} 'requirements.txt'
    if (-not (Test-Path -LiteralPath ${reqFile})) {
        throw ("Locked requirements not staged at {0}; the payload is incomplete." -f ${reqFile})
    }
    ${reqHash} = (Get-FileHash -LiteralPath ${reqFile} -Algorithm SHA256).Hash
    ${stamp}   = Join-Path ${venv} '.mast-requirements.sha256'

    # The guard is the requirements content, NOT whether jupyter-notebook.exe
    # exists. Keying on the exe meant a unit that already had Jupyter skipped the
    # install entirely, so a changed pin could never reach it and the fleet could
    # not be converged by re-running provisioning -- the shape #129 is about.
    ${installed} = if (Test-Path -LiteralPath ${stamp}) { (Get-Content -LiteralPath ${stamp} -Raw).Trim() } else { '' }
    if (${Force} -or ${installed} -ne ${reqHash} -or -not (Test-Path -LiteralPath ${jnExe})) {
        if (${installed} -and ${installed} -ne ${reqHash}) {
            Write-JupyterLog "Locked requirements changed since the last install; reinstalling to converge."
        }
        # --no-index: the wheels are vendored, so this install cannot depend on
        # PyPI reachability, CDN throughput, or the proxy being right at
        # provision time. Jupyter failed on exactly that four times on mast06
        # in three days (#133), and the repo already vendors uv and the NetFx3
        # SxS payload for the same reason.
        #
        # No separate 'pip install --upgrade pip': pip is pinned in the lock
        # (pip==26.2.1) and installed from the wheelhouse with everything else.
        # Upgrading it first would have reached for an index and reintroduced
        # the dependency this removes.
        ${wheels} = Join-Path ${PSScriptRoot} 'wheels'
        if (-not (Test-Path -LiteralPath ${wheels})) {
            throw ("Vendored wheelhouse not staged at {0}; the payload is incomplete." -f ${wheels})
        }
        Invoke-Native -Exe ${venvPy} -NativeArgs @(
            '-m', 'pip', 'install', '--no-index', '--find-links', ${wheels}, '-r', ${reqFile}
        ) -Tag 'pip-install'
        if (-not (Test-Path -LiteralPath ${jnExe})) {
            throw "jupyter-notebook.exe not found after pip install; see the pip-install log."
        }
        # Register a Python kernel contained in the venv (--sys-prefix keeps the
        # kernelspec under the venv, not in the user profile).
        Invoke-Native -Exe ${venvPy} -NativeArgs @('-m', 'ipykernel', 'install', '--sys-prefix', '--name', 'python3', '--display-name', 'Python 3 (MAST)') -Tag 'kernel-register' -TimeoutMs (5 * 60 * 1000)
        # Stamped only after the install succeeded, so a failed run does not
        # convince the next one there is nothing to do.
        Set-Content -LiteralPath ${stamp} -Value ${reqHash} -Encoding ASCII
        Write-JupyterLog ("Stamped locked requirements {0}" -f ${reqHash}.Substring(0, 16))
    } else {
        Write-JupyterLog ("Locked requirements already installed ({0}); skipping pip install." -f ${reqHash}.Substring(0, 16))
    }

    # Log the resolved Jupyter version for the record.
    Invoke-Native -Exe ${venvPy} -NativeArgs @('-m', 'jupyter', '--version') -Tag 'jupyter-version' -TimeoutMs (2 * 60 * 1000)

    # 3) Deploy the launcher (contains all JUPYTER_* state under C:\MAST\jupyter).
    ${launcherSrc} = Join-Path ${PSScriptRoot} 'launch-jupyter.cmd'
    if (-not (Test-Path -LiteralPath ${launcherSrc})) { throw "launch-jupyter.cmd not found beside provide-jupyter.ps1." }
    ${launcherDst} = Join-Path ${JupyterRoot} 'launch-jupyter.cmd'
    Copy-Item -LiteralPath ${launcherSrc} -Destination ${launcherDst} -Force
    Write-JupyterLog ("Deployed launcher: {0}" -f ${launcherDst})

    Write-JupyterLog "Jupyter installation completed successfully."
    exit 0
}
catch {
    ${errorMsg} = ("Jupyter installation failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
