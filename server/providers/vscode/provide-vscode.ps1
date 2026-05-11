param(
    [string]${AssetsRoot} = ".",
    [string]${InstallRoot} = "C:\Program Files\Microsoft VS Code"
)

${ErrorActionPreference} = "Stop"
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "vscode-install.log"
${innoLog} = Join-Path ${logDir} "vscode-inno-setup.log"

function Write-VscodeLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

# Microsoft documents VS Code Windows setup as Inno-based; /S is NSIS-style and can hang under WinRM.
Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] VS Code provide-vscode.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    Write-VscodeLog "Starting VS Code installation (UserSetup = per-user LOCALAPPDATA)."

    ${installerPath} = Join-Path ${AssetsRoot} "VSCodeUserSetup-x64-1.105.1.exe"
    if (-not (Test-Path ${installerPath})) {
        throw "VS Code installer not found at ${installerPath}"
    }

    Write-VscodeLog ("Installer: {0}" -f ${installerPath})
    Write-VscodeLog "Using Inno silent flags + Inno log (see Microsoft VS Code Windows setup docs)."

    ${argList} = @(
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/MERGETASKS=!runcode',
        ('/LOG={0}' -f ${innoLog})
    )
    Write-VscodeLog ("Args: {0}" -f (${argList} -join ' '))

    ${timeoutMs} = 30 * 60 * 1000
    ${p} = Start-Process -FilePath ${installerPath} -ArgumentList ${argList} -PassThru -NoNewWindow
    if (-not ${p}) {
        throw "Start-Process did not return a process object for VS Code setup."
    }
    ${finished} = ${p}.WaitForExit(${timeoutMs})
    if (-not ${finished}) {
        try { ${p}.Kill() } catch {}
        throw ("VS Code installer timed out after 30 minutes (killed). See Inno log: {0}" -f ${innoLog})
    }
    Write-VscodeLog ("VS Code setup exit code: {0}" -f ${p}.ExitCode)
    if (${p}.ExitCode -ne 0) {
        throw ("VS Code setup failed with exit code {0}. See Inno log: {1}" -f ${p}.ExitCode, ${innoLog})
    }

    Start-Sleep -Seconds 5

    # UserSetup installs under the running account's LOCALAPPDATA by default.
    ${vscodeExe} = Get-ChildItem -Path 'C:\Program Files', "$env:LOCALAPPDATA\Programs" `
        -Recurse -Filter 'Code.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not ${vscodeExe}) {
        throw "Code.exe not found after installation (checked Program Files and LOCALAPPDATA\Programs)."
    }
    Write-VscodeLog ("Found Code.exe at: {0}" -f ${vscodeExe})

    Write-VscodeLog "VS Code installation completed successfully"
    exit 0
}
catch {
    ${errorMsg} = "VSCode installation failed: $_"
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
