param(
    [string]${AssetsRoot} = ".",
    [string]${InstallRoot} = "C:\Program Files (x86)\PHDGuiding2"
)

${ErrorActionPreference} = "Stop"
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "phd2-install.log"

function Write-Phd2Log {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-phd2.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    ${installerPath} = Join-Path ${AssetsRoot} "phd2-x64-2.6.13dev7mast04-installer.exe"
    if (-not (Test-Path ${installerPath})) {
        throw "PHD2 installer not found at ${installerPath}"
    }

    Write-Phd2Log ("Running PHD2 installer: {0} /VERYSILENT" -f ${installerPath})
    ${p} = Start-Process -FilePath ${installerPath} -ArgumentList '/VERYSILENT' -PassThru -WindowStyle Hidden
    Write-Phd2Log ("Installer PID: {0}; waiting up to 300s..." -f ${p}.Id)
    ${finished} = ${p}.WaitForExit(300000)
    try { ${p}.Refresh() } catch {}
    if (-not ${finished}) {
        try { ${p}.Kill() } catch {}
        throw "PHD2 installer timed out after 300s (process killed)."
    }
    Write-Phd2Log ("PHD2 installer exited. ExitCode={0}" -f ${p}.ExitCode)
    if ($null -ne ${p}.ExitCode -and ${p}.ExitCode -ne 0) {
        throw ("PHD2 installer failed with exit code {0}" -f ${p}.ExitCode)
    }

    Start-Sleep -Seconds 3
    ${phd2Exe} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
        -Recurse -Filter 'phd2.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not ${phd2Exe}) {
        throw "phd2.exe not found after installation"
    }
    Write-Phd2Log ("Found phd2.exe at: {0}" -f ${phd2Exe})

    # Register PHD2 as an NSSM service so the JSON-RPC event server (port 4400) is reachable.
    # PHD2 is a GUI app; it requires an interactive desktop session to initialise its camera
    # and guiding engine. NSSM with Type=16 (SERVICE_INTERACTIVE_PROCESS) allows it to draw
    # a window in session 0 on Windows 10/11 when the policy is relaxed. For headless units
    # this is sufficient to bring up the event server; the GUI is not needed for automation.
    ${nssmExe} = 'C:\Program Files\nssm\nssm.exe'
    if (Test-Path -LiteralPath ${nssmExe}) {
        ${svcName} = 'PHD2'
        ${existingSvc} = Get-Service -Name ${svcName} -ErrorAction SilentlyContinue
        if ($null -eq ${existingSvc}) {
            Write-Phd2Log "Registering PHD2 as NSSM service..."
            & ${nssmExe} install ${svcName} ${phd2Exe}
            & ${nssmExe} set ${svcName} Start SERVICE_AUTO_START
            & ${nssmExe} set ${svcName} Type 16
            & ${nssmExe} set ${svcName} AppStdout 'C:\MAST\logs\phd2_stdout.log'
            & ${nssmExe} set ${svcName} AppStderr 'C:\MAST\logs\phd2_stderr.log'
            & ${nssmExe} set ${svcName} AppRotateFiles 1
            & ${nssmExe} set ${svcName} AppRotateBytes 10485760
            Start-Service -Name ${svcName} -ErrorAction SilentlyContinue
            Write-Phd2Log "PHD2 service registered and started."
        } else {
            Write-Phd2Log "PHD2 service already registered -- skipping."
        }
    } else {
        Write-Phd2Log "NSSM not found; skipping PHD2 service registration."
    }

    Write-Phd2Log "PHD2 installation completed successfully."
    exit 0
}
catch {
    ${errorMsg} = ("PHD2 installation failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
