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
    # Direct candidates first (fast common case).
    ${candidates} = @(
        (Join-Path ${env:ProgramFiles}        'PHDLogView\phdlogview.exe'),
        (Join-Path ${env:ProgramFiles}        'PHD2 Log Viewer\phdlogview.exe'),
        (Join-Path ${env:ProgramFiles}        'PHD2 Log Viewer\PHD2 Log Viewer.exe'),
        'C:\Program Files\PHDLogView\phdlogview.exe',
        'C:\Program Files\PHD2 Log Viewer\phdlogview.exe',
        'C:\Program Files\PHD2 Log Viewer\PHD2 Log Viewer.exe',
        'C:\Program Files (x86)\PHDLogView\phdlogview.exe',
        'C:\Program Files (x86)\PHD2 Log Viewer\phdlogview.exe',
        'C:\Program Files (x86)\PHD2 Log Viewer\PHD2 Log Viewer.exe'
    )
    foreach (${p} in ${candidates}) {
        if (Test-Path -LiteralPath ${p}) { return ${p} }
    }
    # Fallback: recursive search under Program Files. The Inno installer for
    # this app has changed its install dir name across versions ("PHDLogView"
    # historically, "PHD2 Log Viewer" in 0.6.4 -- run #10 confirmed Start
    # Menu folder name is now "PHD2 Log Viewer"). Catch any future rename.
    foreach (${root} in @('C:\Program Files', 'C:\Program Files (x86)')) {
        if (-not (Test-Path -LiteralPath ${root})) { continue }
        ${hit} = Get-ChildItem -LiteralPath ${root} -Recurse -File `
                    -Include 'phdlogview.exe','PHD2 Log Viewer.exe' `
                    -ErrorAction SilentlyContinue -Depth 3 | Select-Object -First 1
        if (${hit}) { return ${hit}.FullName }
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
    # InnoSetup builds raise even with /VERYSILENT. /LOG=<path> dumps the
    # installer's own decisions to a file so a failed install is debuggable
    # without re-running.
    ${innoLog} = Join-Path (Get-MastLogSessionDir) 'phd2-log-viewer-inno.log'
    Confirm-Dir (Split-Path -Parent ${innoLog})
    Write-Host ("Installing PHDLogView from {0} (inno log: {1}) ..." -f ${installerPath}, ${innoLog})
    ${p} = Start-Process -FilePath ${installerPath} `
        -ArgumentList @('/VERYSILENT', '/SP-', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"${innoLog}`"") `
        -PassThru -Wait -WindowStyle Hidden
    try { ${p}.Refresh() } catch {}
    ${rc} = ${p}.ExitCode
    Write-Host ("PHDLogView installer exit code: {0}" -f ${rc})
    if (Test-Path -LiteralPath ${innoLog}) {
        Write-Host ("--- inno install log tail (last 8 lines of {0}) ---" -f ${innoLog})
        Get-Content -LiteralPath ${innoLog} -Tail 8 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host ("  {0}" -f $_) }
    }
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
