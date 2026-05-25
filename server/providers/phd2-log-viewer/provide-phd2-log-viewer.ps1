#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]${AssetsRoot}    = ${PSScriptRoot},
    [string]${InstallerName} = 'phdlogview_setup-0.6.4.exe'
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

function Get-InstalledPhdLogViewExe {
    ${candidates} = @(
        (Join-Path ${env:ProgramFiles} 'PHDLogView\phdlogview.exe'),
        'C:\Program Files\PHDLogView\phdlogview.exe',
        'C:\Program Files (x86)\PHDLogView\phdlogview.exe'
    )
    foreach (${p} in ${candidates}) {
        if (Test-Path -LiteralPath ${p}) { return ${p} }
    }
    return $null
}

${log} = Start-ProvisionLog -Component 'provide-phd2-log-viewer'
try {
    ${existing} = Get-InstalledPhdLogViewExe
    if (${existing}) {
        Write-Host ("PHDLogView already present at {0}; nothing to do." -f ${existing})
        exit 0
    }

    ${installerPath} = Join-Path ${AssetsRoot} ${InstallerName}
    if (-not (Test-Path ${installerPath})) {
        throw "PHDLogView installer not found: ${installerPath}"
    }

    # InnoSetup installer (per upstream): /VERYSILENT /NORESTART are the
    # canonical unattended switches. /SP- suppresses the "ready to install"
    # prompt; /SUPPRESSMSGBOXES catches stray modal dialogs that some
    # InnoSetup builds raise even with /VERYSILENT.
    Write-Host ("Installing PHDLogView from {0} ..." -f ${installerPath})
    ${p} = Start-Process -FilePath ${installerPath} `
        -ArgumentList @('/VERYSILENT', '/SP-', '/SUPPRESSMSGBOXES', '/NORESTART') `
        -PassThru -Wait -WindowStyle Hidden
    try { ${p}.Refresh() } catch {}
    ${rc} = ${p}.ExitCode
    if ($null -eq ${rc}) {
        throw "PHDLogView installer did not report an exit code (treating as failure)."
    }
    if (${rc} -ne 0 -and ${rc} -ne 3010) {
        throw ("PHDLogView installer exited with code {0}" -f ${rc})
    }

    Start-Sleep -Seconds 2
    ${exe} = Get-InstalledPhdLogViewExe
    if (-not ${exe}) {
        throw "phdlogview.exe not found after install (installer exit ${rc})."
    }
    Write-Host ("PHDLogView installed at {0}" -f ${exe})
}
finally {
    Stop-ProvisionLog
}
exit 0
