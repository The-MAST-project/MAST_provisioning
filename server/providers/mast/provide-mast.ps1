#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]${AssetsRoot} = ${PSScriptRoot},
    [string]${CloneRoot}  = 'C:Users\mast\source\repos'
)

# Import shared helpers
try {
    ${provLocal}  = Join-Path ${PSScriptRoot} 'provisioning.psm1'
    ${provGlobal} = 'C:\ProgramData\MAST\provisioning.psm1'
    if (Test-Path ${provLocal}) {
        Import-Module ${provLocal} -Force
    } elseif (Test-Path ${provGlobal}) {
        Import-Module ${provGlobal} -Force
    } else {
        throw "provisioning.psm1 not found."
    }
}
catch {
    throw "Failed to import provisioning.psm1: $($_.Exception.Message)"
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
    Remove-Item ${tokenFile} -Force -ErrorAction SilentlyContinue

    # Prepare repo root
    Ensure-Dir ${CloneRoot}

    ${repos} = @(
        'github.com/The-MAST-project/MAST_unit.2024-12-12',
        'github.com/The-MAST-project/MAST_common'
    )

    foreach (${repo} in ${repos}) {
        ${repoName} = Split-Path ${repo} -Leaf
        ${targetDir} = Join-Path ${CloneRoot} ${repoName}
        if (Test-Path ${targetDir}) {
            Write-Host "Repo ${repoName} already exists, skipping."
            continue
        }

        ${url} = "https://${token}:x-oauth-basic@${repo}"
        Write-Host "Cloning ${repoName} ..."
        Invoke-Exe -FilePath "git.exe" -Arguments "clone ${url} `"$targetDir`"" -Tag "git-clone"

        # --- Create a per-repo virtualenv at <repo>\.venv ---
        ${venvPath}    = Join-Path ${targetDir} '.venv'
        ${venvPython}  = Join-Path ${venvPath} 'Scripts\python.exe'
        ${reqFile}     = Join-Path ${targetDir} 'requirements.txt'

        if (-not (Test-Path ${venvPython})) {
            Write-Host "Creating virtualenv for ${repoName} at ${venvPath} ..."
            # Prefer virtualenv (installed by your Python provider); fallback to venv if needed
            if (Test-Path ${PythonExe}) {
                # Try: python -m virtualenv .venv
                Invoke-Exe -FilePath ${PythonExe} -Arguments "-m virtualenv `"$venvPath`"" -Tag "venv-create" -IgnoreExitCode:$false
            }
            # Fallback to stdlib venv if virtualenv module isn’t present
            if (-not (Test-Path ${venvPython})) {
                Invoke-Exe -FilePath ${PythonExe} -Arguments "-m venv `"$venvPath`"" -Tag "venv-create-fallback"
            }
        } else {
            Write-Host "Virtualenv already exists for ${repoName}."
        }

        if (-not (Test-Path ${venvPython})) {
            Write-Warning "Failed to create virtualenv for ${repoName}; skipping requirements install."
            continue
        }

        # --- Upgrade pip inside venv (good practice) ---
        Invoke-Exe -FilePath ${venvPython} -Arguments "-m pip install --upgrade pip" -Tag "pip-upgrade"

        # --- Install requirements inside the venv, if present ---
        if (Test-Path ${reqFile}) {
            Write-Host "Installing requirements for ${repoName} in its virtualenv ..."
            Invoke-Exe -FilePath ${venvPython} -Arguments "-m pip install -r `"$reqFile`"" -Tag "pip-install"
        } else {
            Write-Host "No requirements.txt in ${repoName}, skipping pip install."
        }
    }

    Write-Host "Repositories cloned successfully to ${CloneRoot}."
}
finally {
    Stop-ProvisionLog
}
exit 0
