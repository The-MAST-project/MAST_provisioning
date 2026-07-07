#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]${AssetsRoot} = ${PSScriptRoot},
    [string]${InstallerName} = 'Git-2.52.0-64-bit.exe'
)

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

function Get-InstalledGitExe {
    ${candidates} = @(
        (Join-Path ${env:ProgramFiles} 'Git\cmd\git.exe'),
        (Join-Path ${env:ProgramFiles} 'Git\bin\git.exe'),
        'C:\Program Files (x86)\Git\cmd\git.exe',
        'C:\Program Files (x86)\Git\bin\git.exe'
    )
    foreach (${p} in ${candidates}) {
        if (Test-Path -LiteralPath ${p}) { return ${p} }
    }
    return $null
}

function Add-GitDirsToSystemPath {
    param([Parameter(Mandatory)][string]${GitExePath})
    ${gitRoot} = Split-Path (Split-Path ${GitExePath} -Parent) -Parent
    ${cmdPath} = Join-Path ${gitRoot} 'cmd'
    ${binPath} = Join-Path ${gitRoot} 'bin'
    if (Test-Path -LiteralPath ${cmdPath}) { Add-ToSystemPath -Dir ${cmdPath} }
    if (Test-Path -LiteralPath ${binPath}) { Add-ToSystemPath -Dir ${binPath} }
}

${log} = Start-ProvisionLog -Component 'provide-git'
try {
    ${existing} = Get-InstalledGitExe
    if (${existing}) {
        Write-Host ("Git already present at {0}; ensuring PATH." -f ${existing})
        Add-GitDirsToSystemPath -GitExePath ${existing}
        exit 0
    }

    ${installerPath} = Join-Path ${AssetsRoot} ${InstallerName}
    if (-not (Test-Path ${installerPath})) {
        throw "Git installer not found: ${installerPath}"
    }

    Write-Host ("Installing Git for Windows from {0} ..." -f ${installerPath})
    ${p} = Start-Process -FilePath ${installerPath} -ArgumentList @('/VERYSILENT', '/NORESTART') -PassThru -Wait -WindowStyle Hidden
    try { ${p}.Refresh() } catch {}
    if ($null -ne ${p}.ExitCode -and ${p}.ExitCode -ne 0) {
        throw ("Git installer exited with code {0}" -f ${p}.ExitCode)
    }

    Start-Sleep -Seconds 3
    ${gitExe} = Get-InstalledGitExe
    if (-not ${gitExe}) {
        throw "git.exe not found after silent install."
    }
    Add-GitDirsToSystemPath -GitExePath ${gitExe}
    Write-Host ("Git installed; using {0}" -f ${gitExe})
}
finally {
    Stop-ProvisionLog
}
exit 0
