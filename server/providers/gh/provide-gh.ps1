#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]${AssetsRoot}    = ${PSScriptRoot},
    [string]${InstallerName} = 'gh_2.92.0_windows_amd64.msi'
)

# --- Import shared helpers (PS 5.1 safe) ---
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

function Get-InstalledGhExe {
    ${candidates} = @(
        (Join-Path ${env:ProgramFiles} 'GitHub CLI\gh.exe'),
        'C:\Program Files\GitHub CLI\gh.exe',
        'C:\Program Files (x86)\GitHub CLI\gh.exe'
    )
    foreach (${p} in ${candidates}) {
        if (Test-Path -LiteralPath ${p}) { return ${p} }
    }
    return $null
}

${log} = Start-ProvisionLog -Component 'provide-gh'
try {
    ${existing} = Get-InstalledGhExe
    if (${existing}) {
        Write-Host ("GitHub CLI already present at {0}; ensuring PATH." -f ${existing})
        Add-ToSystemPath -Dir (Split-Path -Parent ${existing})
        exit 0
    }

    ${installerPath} = Join-Path ${AssetsRoot} ${InstallerName}
    if (-not (Test-Path ${installerPath})) {
        throw "GitHub CLI installer not found: ${installerPath}"
    }

    # MSI install. msiexec is the universal silent install path for .msi;
    # /qn = no UI, /norestart = never auto-reboot.
    ${msiLog} = Join-Path (Get-MastLogSessionDir) 'gh-msi.log'
    Confirm-Dir (Split-Path -Parent ${msiLog})
    Write-Host ("Installing GitHub CLI from {0} ..." -f ${installerPath})
    ${msiArgs} = @(
        '/i', ${installerPath},
        '/qn', '/norestart',
        '/L*v', ${msiLog}
    )
    ${p} = Start-Process -FilePath 'msiexec.exe' -ArgumentList ${msiArgs} `
        -PassThru -Wait -WindowStyle Hidden
    try { ${p}.Refresh() } catch {}
    ${rc} = ${p}.ExitCode
    if ($null -eq ${rc}) {
        throw "msiexec.exe did not report an exit code (treating as failure). See ${msiLog}"
    }
    # 0 = success, 3010 = success but reboot required (acceptable).
    if (${rc} -ne 0 -and ${rc} -ne 3010) {
        throw ("msiexec for gh exited with code {0}. See ${msiLog}" -f ${rc})
    }

    # The MSI updates the system PATH but the current process inherits the
    # old PATH; not a problem for our own verify (which uses Test-Path on
    # the install dir), but we still call Add-ToSystemPath defensively in
    # case the MSI variant skips the env-var write on a future release.
    Start-Sleep -Seconds 2
    ${ghExe} = Get-InstalledGhExe
    if (-not ${ghExe}) {
        throw ("gh.exe not found after MSI install. msiexec exit was {0}; check {1}." -f ${rc}, ${msiLog})
    }
    Add-ToSystemPath -Dir (Split-Path -Parent ${ghExe})
    Write-Host ("GitHub CLI installed at {0}" -f ${ghExe})
}
finally {
    Stop-ProvisionLog
}
exit 0
