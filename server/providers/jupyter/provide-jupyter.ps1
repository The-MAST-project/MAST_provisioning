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
    ${proc} = Start-Process -FilePath ${Exe} -ArgumentList ${NativeArgs} -PassThru -NoNewWindow `
        -RedirectStandardOutput ${out} -RedirectStandardError ("{0}.err" -f ${out})
    if (-not ${proc}) { throw ("Start-Process returned no object for {0}" -f ${Tag}) }
    if (-not ${proc}.WaitForExit(${TimeoutMs})) {
        try { & taskkill.exe /T /F /PID $(${proc}.Id) 2>$null | Out-Null } catch {}
        try { ${proc}.Kill() } catch {}
        throw ("{0} timed out; process tree killed. See {1}" -f ${Tag}, ${out})
    }
    try { ${proc}.Refresh() } catch {}
    Write-JupyterLog ("{0} exit={1} (log {2})" -f ${Tag}, ${proc}.ExitCode, ${out})
    if (${proc}.ExitCode -ne 0) { throw ("{0} failed (exit {1}); see {2}" -f ${Tag}, ${proc}.ExitCode, ${out}) }
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

    # 1) Dedicated venv (mirrors the mast provider: virtualenv, fallback to stdlib venv).
    if (${Force} -and (Test-Path -LiteralPath ${venv})) {
        Write-JupyterLog "Force: removing existing venv."
        Remove-Item -LiteralPath ${venv} -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath ${venvPy})) {
        Write-JupyterLog ("Creating venv at {0}" -f ${venv})
        Invoke-Native -Exe ${PythonExe} -NativeArgs @('-m', 'virtualenv', ${venv}) -Tag 'venv-create' -TimeoutMs (5 * 60 * 1000)
        if (-not (Test-Path -LiteralPath ${venvPy})) {
            Write-JupyterLog "virtualenv did not yield python.exe; falling back to stdlib venv."
            Invoke-Native -Exe ${PythonExe} -NativeArgs @('-m', 'venv', ${venv}) -Tag 'venv-create-fallback' -TimeoutMs (5 * 60 * 1000)
        }
        if (-not (Test-Path -LiteralPath ${venvPy})) { throw ("Failed to create venv at {0}" -f ${venv}) }
    } else {
        Write-JupyterLog "venv already present; skipping creation."
    }

    # 2) Install Jupyter Notebook + a Python kernel INTO the venv (online pip via the
    #    proxy, same mechanism the mast provider uses for repo requirements). Skip if
    #    already installed unless -Force.
    if (${Force} -or -not (Test-Path -LiteralPath ${jnExe})) {
        Invoke-Native -Exe ${venvPy} -NativeArgs @('-m', 'pip', 'install', '--upgrade', 'pip') -Tag 'pip-upgrade'
        Invoke-Native -Exe ${venvPy} -NativeArgs @('-m', 'pip', 'install', 'notebook>=7,<8', 'ipykernel') -Tag 'pip-install'
        if (-not (Test-Path -LiteralPath ${jnExe})) {
            throw "jupyter-notebook.exe not found after pip install; see the pip-install log."
        }
        # Register a Python kernel contained in the venv (--sys-prefix keeps the
        # kernelspec under the venv, not in the user profile).
        Invoke-Native -Exe ${venvPy} -NativeArgs @('-m', 'ipykernel', 'install', '--sys-prefix', '--name', 'python3', '--display-name', 'Python 3 (MAST)') -Tag 'kernel-register' -TimeoutMs (5 * 60 * 1000)
    } else {
        Write-JupyterLog "jupyter-notebook.exe already present; skipping pip install."
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
