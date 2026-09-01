#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]${AssetsRoot} = ${PSScriptRoot},
    [string]${Installer}  = "python-3.12.2-amd64.exe",
    [string]${InstallDir} = "C:\Python312",
    # Reinstall even if Python is already present. Without it an existing install
    # is left as-is (the installer is skipped) and only the pip chain, the
    # virtualenv removal and the assertions below run.
    [switch]${Force}
)

# --- Import shared helpers ---
try {
    ${provLocal}  = Join-Path ${PSScriptRoot} 'provisioning.psm1'
    ${provGlobal} = 'C:\ProgramData\MAST\provisioning.psm1'
    if (Test-Path ${provLocal}) {
        Import-Module ${provLocal} -Force -ErrorAction Stop -DisableNameChecking
    }
    elseif (Test-Path ${provGlobal}) {
        Import-Module ${provGlobal} -Force -ErrorAction Stop -DisableNameChecking
    }
    else {
        throw "provisioning.psm1 not found next to script or in ${provGlobal}"
    }
}
catch {
    throw "Failed to import provisioning.psm1: $($_.Exception.Message)"
}

function Get-ProbeExitCode {
    # Exit code of a native probe, with its output kept out of the log.
    #
    # $ErrorActionPreference is forced to SilentlyContinue for the call. A native
    # command that writes to stderr produces a PowerShell error record, and
    # `*>$null` does NOT prevent it -- it only hides the text. `pip show <absent
    # package>` writes "WARNING: Package(s) not found" and exits 1, which is the
    # answer these probes want, so the record was pure noise: two
    # NativeCommandError blocks in the transcript of a passing run, indistinguishable
    # at a glance from a real fault. Under 'Stop' the same records terminate the
    # script, which is how verify-python.ps1 first died on the dev VM.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]${Exe},
        [Parameter(Mandatory)][string[]]${NativeArgs}
    )
    ${prev} = ${ErrorActionPreference}
    ${ErrorActionPreference} = 'SilentlyContinue'
    try {
        ${null} = & ${Exe} @NativeArgs 2>&1
        return ${LASTEXITCODE}
    }
    finally { ${ErrorActionPreference} = ${prev} }
}

# Idempotent skip: the end state this provider produces is Python present, the
# stdlib venv module usable, pip available, and virtualenv NOT installed. All four
# clauses matter, and the last one is what keeps the removal below reachable: a
# guard testing only python+venv would exit 0 on exactly the units that still
# carry virtualenv -- every unit provisioned before it was dropped -- so the
# package would survive forever on the machines the cleanup exists for. That is
# the shape of #129, a guard weaker than what the module actually produces.
${pythonExeGuard} = Join-Path ${InstallDir} 'python.exe'
if (-not ${Force} -and (Test-Path ${pythonExeGuard})) {
    ${venvUsable}     = (Get-ProbeExitCode -Exe ${pythonExeGuard} -NativeArgs @('-m', 'venv', '--help')) -eq 0
    ${pipPresent}     = (Get-ProbeExitCode -Exe ${pythonExeGuard} -NativeArgs @('-m', 'pip', '--version')) -eq 0
    ${virtualenvGone} = (Get-ProbeExitCode -Exe ${pythonExeGuard} -NativeArgs @('-m', 'pip', 'show', 'virtualenv')) -ne 0
    if (${venvUsable} -and ${pipPresent} -and ${virtualenvGone}) {
        Add-ToSystemPath -Dir ${InstallDir}
        Write-Host "Python + pip + stdlib venv already in place at ${InstallDir}, virtualenv absent; skipping installer. Use -Force to reinstall."
        exit 0
    }
}

${null} = Start-ProvisionLog -Component 'provide-python'
try {
    ${pythonExe} = Join-Path ${InstallDir} 'python.exe'

    # --- Install Python silently (skipped when it is already there) ---
    if (${Force} -or -not (Test-Path ${pythonExe})) {
        ${exePath} = Join-Path ${AssetsRoot} ${Installer}
        if (-not (Test-Path ${exePath})) {
            throw "Python installer not found: ${exePath}"
        }
        Write-Host "Installing Python from ${Installer} ..."
        ${installer_args} = "/quiet InstallAllUsers=1 PrependPath=1 TargetDir=`"${InstallDir}`" Include_test=0 Include_doc=0"
        Invoke-Exe -FilePath ${exePath} -Arguments ${installer_args} -Tag "python-install"
        if (-not (Test-Path ${pythonExe})) {
            throw "python.exe not found in ${InstallDir} after the installer ran; the installation failed."
        }
    }
    else {
        Write-Host "Python already installed at ${InstallDir}; skipping installer."
    }
    Add-ToSystemPath -Dir ${InstallDir}

    # --- Ensure pip is present ---
    # provide-jupyter installs its locked wheelhouse with pip (--no-index), so a
    # missing pip is a failed run rather than a cosmetic gap. Nothing is upgraded:
    # a pip upgrade is a second PyPI fetch buying nothing this provider needs.
    Write-Host "Ensuring pip is available ..."
    ${env:PIP_NO_WARN_SCRIPT_LOCATION} = '1'
    & ${pythonExe} -m ensurepip --default-pip
    if (${LASTEXITCODE} -ne 0) {
        throw "python -m ensurepip --default-pip failed (exit ${LASTEXITCODE})."
    }

    # --- Remove virtualenv where an earlier run installed it ---
    # virtualenv was dropped for the stdlib venv module (#131): installing it was
    # the last PyPI fetch left in a provisioning run, and its only consumer,
    # provide-jupyter.ps1, already had a stdlib-venv path. Uninstalling needs no
    # network, so this is safe on a unit with no route to an index. Existing
    # jupyter venvs built by virtualenv are left alone; they work.
    if ((Get-ProbeExitCode -Exe ${pythonExe} -NativeArgs @('-m', 'pip', 'show', 'virtualenv')) -eq 0) {
        Write-Host "Removing virtualenv (superseded by the stdlib venv module) ..."
        & ${pythonExe} -m pip uninstall -y virtualenv
        if (${LASTEXITCODE} -ne 0) {
            throw "pip uninstall of virtualenv failed (exit ${LASTEXITCODE})."
        }
    }
    else {
        Write-Host "virtualenv not installed; nothing to remove."
    }

    # --- Assert the end state, do not warn about not having it (#62, #131) ---
    ${verPy} = & ${pythonExe} --version
    if (${LASTEXITCODE} -ne 0) {
        throw "${pythonExe} --version failed (exit ${LASTEXITCODE})."
    }
    Write-Host "Python version: ${verPy}"
    ${venvRc} = Get-ProbeExitCode -Exe ${pythonExe} -NativeArgs @('-m', 'venv', '--help')
    if (${venvRc} -ne 0) {
        throw "the stdlib venv module is not usable (python -m venv --help exit ${venvRc}); provide-jupyter creates its venv with it."
    }
    if ((Get-ProbeExitCode -Exe ${pythonExe} -NativeArgs @('-m', 'pip', 'show', 'virtualenv')) -eq 0) {
        throw "virtualenv is still installed after the removal above."
    }
    Write-Host "stdlib venv usable, virtualenv absent."
}
finally {
    Stop-ProvisionLog
}
exit 0
