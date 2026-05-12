#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]${AssetsRoot} = ${PSScriptRoot},
    [string]${CloneRoot}  = 'C:\Users\mast\source\repos'
)

# Import shared helpers
try {
    ${provLocal}  = Join-Path ${PSScriptRoot} 'provisioning.psm1'
    ${provGlobal} = 'C:\ProgramData\MAST\provisioning.psm1'
    if (Test-Path ${provLocal}) {
        Import-Module ${provLocal} -Force -DisableNameChecking
    } elseif (Test-Path ${provGlobal}) {
        Import-Module ${provGlobal} -Force -DisableNameChecking
    } else {
        throw "provisioning.psm1 not found."
    }
}
catch {
    throw "Failed to import provisioning.psm1: $($_.Exception.Message)"
}

${mastRepoListScript} = Join-Path ${PSScriptRoot} 'mast-repo-list.ps1'
if (-not (Test-Path -LiteralPath ${mastRepoListScript})) {
    throw "mast-repo-list.ps1 not found beside provide-mast.ps1."
}
. ${mastRepoListScript}

function Update-MastProcessPathFromRegistry {
    ${machinePath} = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    ${userPath} = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (${machinePath} -and ${userPath}) {
        ${env:Path} = ${machinePath} + ';' + ${userPath}
    } elseif (${machinePath}) {
        ${env:Path} = ${machinePath}
    } elseif (${userPath}) {
        ${env:Path} = ${userPath}
    }
}

function Resolve-MastGitExe {
    ${candidates} = @(
        'C:\Program Files\Git\cmd\git.exe',
        'C:\Program Files\Git\bin\git.exe',
        'C:\Program Files (x86)\Git\cmd\git.exe',
        'C:\Program Files (x86)\Git\bin\git.exe'
    )
    foreach (${c} in ${candidates}) {
        if (Test-Path -LiteralPath ${c}) { return ${c} }
    }
    Update-MastProcessPathFromRegistry
    ${cmdObj} = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (${cmdObj} -and (Test-Path -LiteralPath ${cmdObj}.Source)) {
        return ${cmdObj}.Source
    }
    foreach (${c} in ${candidates}) {
        if (Test-Path -LiteralPath ${c}) { return ${c} }
    }
    return $null
}

# Ensure Git is installed (Git for Windows; VS Code does not supply this layout)
${gitExe} = Resolve-MastGitExe
if (-not ${gitExe}) {
    ${installerPath} = Join-Path ${AssetsRoot} "Git-2.52.0-64-bit.exe"
    if (-not (Test-Path ${installerPath})) {
        throw "Git installer not found at ${installerPath}. Add Git for Windows to assets or preinstall Git; VS Code does not install Git to C:\Program Files\Git."
    }
    & ${installerPath} /VERYSILENT
    Start-Sleep -Seconds 3
    Update-MastProcessPathFromRegistry
    ${gitExe} = Resolve-MastGitExe
}
if (-not ${gitExe}) {
    throw ("Git not found after silent install. Confirm Git for Windows completed or add git.exe to PATH. Asset: {0}" -f (Join-Path ${AssetsRoot} "Git-2.52.0-64-bit.exe"))
}
Write-Host "Using Git at: ${gitExe}"

function Write-MastProvisionEvent {
    param([Parameter(Mandatory)][string]${Message})
    ${ts} = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    Write-Host ("[{0}] [provide-mast] {1}" -f ${ts}, ${Message})
}

function Get-MastGitHubHttpsCloneUrls {
    param(
        [Parameter(Mandatory)][string]${RepoSpec},
        [Parameter(Mandatory)][string]${Token}
    )
    # ${RepoSpec} example: github.com/The-MAST-project/MAST_common
    ${plainHttps} = ("https://{0}.git" -f ${RepoSpec})
    if (${RepoSpec} -notmatch '(?i)^github\.com/') {
        return @{ CloneUrl = ${plainHttps}; LogUrl = ${plainHttps} }
    }
    ${pathOnly} = ${RepoSpec} -replace '(?i)^github\.com/', ''
    ${encToken} = [Uri]::EscapeDataString(${Token})
    ${authClone} = ("https://x-access-token:{0}@github.com/{1}.git" -f ${encToken}, ${pathOnly})
    ${safeLog} = ("https://github.com/{0}.git" -f ${pathOnly})
    return @{ CloneUrl = ${authClone}; LogUrl = ${safeLog} }
}

function Invoke-MastGitCloneObserved {
    param(
        [Parameter(Mandatory)][string]${GitExe},
        [Parameter(Mandatory)][string]${CloneUrl},
        [Parameter(Mandatory)][string]${UrlForLog},
        [Parameter(Mandatory)][string]${TargetDir},
        [Parameter(Mandatory)][string]${RepoLabel},
        [Parameter(Mandatory)][string]${LogDir}
    )
    ${stderrLog} = Join-Path ${LogDir} ("{0}.git-clone.stderr.log" -f ${RepoLabel})
    ${stdoutLog} = Join-Path ${LogDir} ("{0}.git-clone.stdout.log" -f ${RepoLabel})
    Remove-Item -LiteralPath ${stderrLog} -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ${stdoutLog} -Force -ErrorAction SilentlyContinue
    # Avoid indefinite hang on interactive credential prompts when non-interactive.
    ${prevPrompt} = ${env:GIT_TERMINAL_PROMPT}
    ${env:GIT_TERMINAL_PROMPT} = '0'
    ${prevGcm} = ${env:GCM_INTERACTIVE}
    ${env:GCM_INTERACTIVE} = 'false'
    ${prevTrace} = ${env:GIT_TRACE}
    ${traceLog} = Join-Path ${LogDir} ("{0}.git-trace.log" -f ${RepoLabel})
    Remove-Item -LiteralPath ${traceLog} -Force -ErrorAction SilentlyContinue
    ${env:GIT_TRACE} = ${traceLog}
    try {
        Write-MastProvisionEvent ("git clone BEGIN repo={0} url={1} targetDir={2}" -f ${RepoLabel}, ${UrlForLog}, ${TargetDir})
        Write-MastProvisionEvent ("git clone hint: Explorer hides .git; empty-looking folder may still be cloning.")
        Write-MastProvisionEvent ("git clone logs: stderr={0} stdout={1} GIT_TRACE={2}" -f ${stderrLog}, ${stdoutLog}, ${traceLog})
        ${sw} = [System.Diagnostics.Stopwatch]::StartNew()
        # credential.interactive=never: fail instead of waiting for GCM UI.
        # http.lowSpeed*: abort if the HTTP layer stalls (common misread as hang).
        ${argList} = @(
            '-c', 'credential.interactive=never',
            '-c', 'http.lowSpeedLimit=100',
            '-c', 'http.lowSpeedTime=120',
            'clone', '--progress', ${CloneUrl}, ${TargetDir}
        )
        ${p} = Start-Process -FilePath ${GitExe} -ArgumentList ${argList} -PassThru -Wait -WindowStyle Hidden `
            -RedirectStandardError ${stderrLog} -RedirectStandardOutput ${stdoutLog}
        try { ${p}.Refresh() } catch {}
        ${sw}.Stop()
        Write-MastProvisionEvent ("git clone END repo={0} elapsedSec={1:N1} pidExitCode={2}" -f ${RepoLabel}, ${sw}.Elapsed.TotalSeconds, ${p}.ExitCode)
        if (${null} -eq ${p}.ExitCode) {
            throw "git-clone: missing exit code after Wait (treat as failure). See stderr log: ${stderrLog}"
        }
        if (${p}.ExitCode -ne 0) {
            ${tailErr} = ''
            if (Test-Path -LiteralPath ${stderrLog}) {
                ${tailErr} = ((Get-Content -LiteralPath ${stderrLog} -ErrorAction SilentlyContinue) | Select-Object -Last 40) -join [Environment]::NewLine
            }
            throw ("git-clone failed exitCode={0}. Last stderr lines:{1}{2}" -f ${p}.ExitCode, [Environment]::NewLine, ${tailErr})
        }
        if (Test-Path -LiteralPath (Join-Path ${TargetDir} '.git')) {
            ${head} = ''
            ${revOut} = Join-Path ${LogDir} ("{0}.git-revparse.stdout.log" -f ${RepoLabel})
            ${revErr} = Join-Path ${LogDir} ("{0}.git-revparse.stderr.log" -f ${RepoLabel})
            Remove-Item -LiteralPath ${revOut} -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ${revErr} -Force -ErrorAction SilentlyContinue
            try {
                ${argRev} = @('-C', ${TargetDir}, 'rev-parse', 'HEAD')
                ${pr} = Start-Process -FilePath ${GitExe} -ArgumentList ${argRev} -PassThru -Wait -WindowStyle Hidden `
                    -RedirectStandardError ${revErr} -RedirectStandardOutput ${revOut}
                try { ${pr}.Refresh() } catch {}
                if (${null} -ne ${pr}.ExitCode -and ${pr}.ExitCode -eq 0) {
                    ${head} = ((Get-Content -LiteralPath ${revOut} -ErrorAction SilentlyContinue) | Select-Object -First 1).Trim()
                }
            }
            catch { }
            if (${head}) { Write-MastProvisionEvent ("git rev-parse HEAD repo={0} => {1}" -f ${RepoLabel}, ${head}) }
        }
    }
    finally {
        if (${null} -ne ${prevPrompt}) { ${env:GIT_TERMINAL_PROMPT} = ${prevPrompt} } else { Remove-Item Env:\GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue }
        if (${null} -ne ${prevGcm}) { ${env:GCM_INTERACTIVE} = ${prevGcm} } else { Remove-Item Env:\GCM_INTERACTIVE -ErrorAction SilentlyContinue }
        if (${null} -ne ${prevTrace}) { ${env:GIT_TRACE} = ${prevTrace} } else { Remove-Item Env:\GIT_TRACE -ErrorAction SilentlyContinue }
    }
}

function Invoke-MastExePhase {
    param(
        [Parameter(Mandatory)][string]${FilePath},
        [Parameter(Mandatory)][string]${Arguments},
        [Parameter(Mandatory)][string]${Tag}
    )
    Write-MastProvisionEvent ("{0} BEGIN exe={1}" -f ${Tag}, ${FilePath})
    ${sw} = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-Exe -FilePath ${FilePath} -Arguments ${Arguments} -Tag ${Tag}
    }
    finally {
        ${sw}.Stop()
        Write-MastProvisionEvent ("{0} END elapsedSec={1:N1}" -f ${Tag}, ${sw}.Elapsed.TotalSeconds)
    }
}

${log} = Start-ProvisionLog -Component 'provide-github'
try {
    ${tokenFile} = Join-Path ${PSScriptRoot} 'mast_github.txt'
    if (-not (Test-Path ${tokenFile})) {
        throw "Token file not found: ${tokenFile}"
    }

    ${token} = (Get-Content ${tokenFile} -ErrorAction Stop).Trim()
    if (-not ${token}) {
        throw "Token file is empty."
    }

    # Optionally delete immediately after reading
    # Remove-Item ${tokenFile} -Force -ErrorAction SilentlyContinue

    # Prepare repo root
    Confirm-Dir ${CloneRoot}

    ${repoListPath} = Join-Path ${PSScriptRoot} 'mast-repos.txt'
    ${repos} = Read-MastRepoSpecFile -Path ${repoListPath}

    ${PythonExe} = "C:\Python312\python.exe"
    foreach (${repo} in ${repos}) {
        ${repoName} = Split-Path ${repo} -Leaf
        ${targetDir} = Join-Path ${CloneRoot} ${repoName}
        Write-MastProvisionEvent ("repo phase START name={0} targetDir={1}" -f ${repoName}, ${targetDir})
        ${gitDirMarker} = Join-Path ${targetDir} '.git'
        if ((Test-Path -LiteralPath ${targetDir}) -and (Test-Path -LiteralPath ${gitDirMarker})) {
            Write-MastProvisionEvent ("repo SKIP (clone already present, .git exists) name={0}" -f ${repoName})
            Write-Host "Repo ${repoName} already exists, skipping."
            continue
        }
        if ((Test-Path -LiteralPath ${targetDir}) -and -not (Test-Path -LiteralPath ${gitDirMarker})) {
            Write-MastProvisionEvent ("repo REMEDIATION removing incomplete directory (no .git) name={0}" -f ${repoName})
            Remove-Item -LiteralPath ${targetDir} -Recurse -Force -ErrorAction SilentlyContinue
        }

        ${urls} = Get-MastGitHubHttpsCloneUrls -RepoSpec ${repo} -Token ${token}
        ${cloneUrlUse} = ${urls}['CloneUrl']
        ${logUrlUse} = ${urls}['LogUrl']
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue ${targetDir}
        Invoke-MastGitCloneObserved -GitExe ${gitExe} -CloneUrl ${cloneUrlUse} -UrlForLog ${logUrlUse} -TargetDir ${targetDir} -RepoLabel ${repoName} -LogDir ${CloneRoot}

        # --- Pull git submodules if .gitmodules is present ---
        ${gitModulesFile} = Join-Path ${targetDir} '.gitmodules'
        if (Test-Path -LiteralPath ${gitModulesFile}) {
            Write-MastProvisionEvent ("git submodule update BEGIN repo={0}" -f ${repoName})
            ${subArgs} = @('-C', ${targetDir}, 'submodule', 'update', '--init', '--recursive')
            ${subOut} = Join-Path ${CloneRoot} ("{0}.submodule.stdout.log" -f ${repoName})
            ${subErr} = Join-Path ${CloneRoot} ("{0}.submodule.stderr.log" -f ${repoName})
            ${prevPrompt2} = ${env:GIT_TERMINAL_PROMPT}
            ${env:GIT_TERMINAL_PROMPT} = '0'
            try {
                ${ps2} = Start-Process -FilePath ${gitExe} -ArgumentList ${subArgs} -PassThru -Wait -WindowStyle Hidden `
                    -RedirectStandardOutput ${subOut} -RedirectStandardError ${subErr}
                try { ${ps2}.Refresh() } catch {}
                if ($null -ne ${ps2}.ExitCode -and ${ps2}.ExitCode -ne 0) {
                    ${tailErr2} = ((Get-Content -LiteralPath ${subErr} -ErrorAction SilentlyContinue) | Select-Object -Last 20) -join [Environment]::NewLine
                    throw ("git submodule update failed exitCode={0}:{1}{2}" -f ${ps2}.ExitCode, [Environment]::NewLine, ${tailErr2})
                }
            }
            finally {
                if ($null -ne ${prevPrompt2}) { ${env:GIT_TERMINAL_PROMPT} = ${prevPrompt2} } else { Remove-Item Env:\GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue }
            }
            Write-MastProvisionEvent ("git submodule update DONE repo={0}" -f ${repoName})
        }

        # --- Create a per-repo virtualenv at <repo>\.venv ---
        ${venvPath}    = Join-Path ${targetDir} '.venv'
        ${venvPython}  = Join-Path ${venvPath} 'Scripts\python.exe'
        ${reqFile}     = Join-Path ${targetDir} 'requirements.txt'

        if (-not (Test-Path ${venvPython})) {
            Write-MastProvisionEvent ("virtualenv create path={0}" -f ${venvPath})
            # Prefer virtualenv (installed by your Python provider); fallback to venv if needed
            if (Test-Path ${PythonExe}) {
                # Try: python -m virtualenv .venv
                Invoke-MastExePhase -FilePath ${PythonExe} -Arguments "-m virtualenv `"$venvPath`"" -Tag ("venv-create:{0}" -f ${repoName})
            }
            # Fallback to stdlib venv if virtualenv module isn't present
            if (-not (Test-Path ${venvPython})) {
                Invoke-MastExePhase -FilePath ${PythonExe} -Arguments "-m venv `"$venvPath`"" -Tag ("venv-create-fallback:{0}" -f ${repoName})
            }
        } else {
            Write-MastProvisionEvent ("virtualenv SKIP (already exists) name={0}" -f ${repoName})
            Write-Host "Virtualenv already exists for ${repoName}."
        }

        if (-not (Test-Path ${venvPython})) {
            Write-Warning "Failed to create virtualenv for ${repoName}; skipping requirements install."
            continue
        }

        # --- Upgrade pip inside venv (good practice) ---
        Invoke-MastExePhase -FilePath ${venvPython} -Arguments "-m pip install --upgrade pip" -Tag ("pip-upgrade:{0}" -f ${repoName})

        # --- Install requirements inside the venv, if present ---
        if (Test-Path ${reqFile}) {
            Write-MastProvisionEvent ("pip install -r requirements.txt path={0}" -f ${reqFile})
            Invoke-MastExePhase -FilePath ${venvPython} -Arguments "-m pip install -r `"$reqFile`"" -Tag ("pip-install:{0}" -f ${repoName})
        } else {
            Write-MastProvisionEvent ("pip SKIP (no requirements.txt) name={0}" -f ${repoName})
            Write-Host "No requirements.txt in ${repoName}, skipping pip install."
        }
        # --- Register MAST_unit as a Windows service via NSSM ---
        if (${repoName} -like 'MAST_unit*') {
            ${nssmExe} = 'C:\Program Files\nssm\nssm.exe'
            ${serviceName} = 'MAST_unit'
            # Entry point: adjust if the unit script lives elsewhere in the repo.
            ${unitEntryPoint} = Join-Path ${targetDir} 'unit\unit.py'
            ${venvPythonSvc} = Join-Path ${venvPath} 'Scripts\python.exe'
            if (-not (Test-Path -LiteralPath ${nssmExe})) {
                Write-Warning "NSSM not found at ${nssmExe}; skipping MAST_unit service registration."
            } elseif (-not (Test-Path -LiteralPath ${unitEntryPoint})) {
                Write-Warning ("MAST_unit entry point not found at {0}; skipping service registration." -f ${unitEntryPoint})
            } else {
                ${existingSvc} = Get-Service -Name ${serviceName} -ErrorAction SilentlyContinue
                if ($null -eq ${existingSvc}) {
                    Write-MastProvisionEvent ("NSSM service register BEGIN name={0}" -f ${serviceName})
                    & ${nssmExe} install ${serviceName} ${venvPythonSvc} ${unitEntryPoint}
                    & ${nssmExe} set ${serviceName} AppDirectory ${targetDir}
                    & ${nssmExe} set ${serviceName} Start SERVICE_AUTO_START
                    & ${nssmExe} set ${serviceName} AppStdout 'C:\MAST\logs\mast_unit_stdout.log'
                    & ${nssmExe} set ${serviceName} AppStderr 'C:\MAST\logs\mast_unit_stderr.log'
                    & ${nssmExe} set ${serviceName} AppRotateFiles 1
                    & ${nssmExe} set ${serviceName} AppRotateBytes 10485760
                    Start-Service -Name ${serviceName} -ErrorAction SilentlyContinue
                    Write-MastProvisionEvent ("NSSM service register DONE name={0}" -f ${serviceName})
                } else {
                    Write-MastProvisionEvent ("NSSM service SKIP (already registered) name={0}" -f ${serviceName})
                }
            }
        }

        Write-MastProvisionEvent ("repo phase DONE name={0}" -f ${repoName})
    }

    Write-Host "Repositories cloned successfully to ${CloneRoot}."
}
finally {
    Stop-ProvisionLog
}
exit 0
