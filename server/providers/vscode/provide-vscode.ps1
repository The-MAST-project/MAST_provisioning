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

    ${installerPath} = Join-Path ${AssetsRoot} "VSCodeUserSetup-x64-1.121.0.exe"
    if (-not (Test-Path ${installerPath})) {
        throw "VS Code installer not found at ${installerPath}"
    }

    Write-VscodeLog ("Installer: {0}" -f ${installerPath})
    # Idempotent re-run guard: skip the Inno UserSetup installer if VS Code is
    # already present. Code.exe presence is the authoritative success criterion;
    # re-running an Inno installer over an existing install can stall under WinRM
    # Session 0. (Same pattern as phd2/planewave/zwo.)
    ${vscodeExe} = Get-ChildItem -Path 'C:\Program Files', "$env:LOCALAPPDATA\Programs" `
        -Recurse -Filter 'Code.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName

    if (${vscodeExe}) {
        Write-VscodeLog ("VS Code already installed at {0}; skipping installer (idempotent re-run)." -f ${vscodeExe})
    } else {
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
            try { & taskkill.exe /T /F /PID $(${p}.Id) 2>$null | Out-Null } catch {}
            try { ${p}.Kill() } catch {}
            throw ("VS Code installer timed out after 30 minutes (process tree killed). See Inno log: {0}" -f ${innoLog})
        }
        try { ${p}.Refresh() } catch {}
        Write-VscodeLog ("VS Code setup exit code: {0}" -f ${p}.ExitCode)

        Start-Sleep -Seconds 5

        # UserSetup installs under the running account's LOCALAPPDATA by default.
        ${vscodeExe} = Get-ChildItem -Path 'C:\Program Files', "$env:LOCALAPPDATA\Programs" `
            -Recurse -Filter 'Code.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
        # A non-zero installer exit is not fatal if Code.exe is present.
        if ($null -ne ${p}.ExitCode -and ${p}.ExitCode -ne 0) {
            if (${vscodeExe}) {
                Write-VscodeLog ("[WARN] setup exit {0} but Code.exe present; treating as installed. See Inno log: {1}" -f ${p}.ExitCode, ${innoLog})
            } else {
                throw ("VS Code setup failed with exit code {0} and Code.exe is absent. See Inno log: {1}" -f ${p}.ExitCode, ${innoLog})
            }
        }
        if (-not ${vscodeExe}) {
            throw "Code.exe not found after installation (checked Program Files and LOCALAPPDATA\Programs)."
        }
    }
    Write-VscodeLog ("Found Code.exe at: {0}" -f ${vscodeExe})

    # --- Install bundled extensions (offline .vsix) into the running user's profile ---
    # Provisioning runs as the mast account (WinRM/Invoke-Command with the unit
    # cred), so both VS Code (UserSetup) and these extensions land in mast's
    # profile (C:\Users\mast\.vscode\extensions). We install from staged .vsix
    # files rather than `--install-extension <id>` so there is NO dependency on
    # the VS Code marketplace being reachable (units are behind bcproxy) -- the
    # same offline-installer principle used for every other provider. Runs on both
    # the fresh-install and idempotent-skip paths so a re-provision refreshes them.
    # Pinned, field-proven, win32-x64 builds; both satisfy VS Code 1.121.0's engine
    # (debugpy ^1.92.0, python ^1.95.0).
    ${codeCmd} = Join-Path (Split-Path -Parent ${vscodeExe}) 'bin\code.cmd'
    if (-not (Test-Path -LiteralPath ${codeCmd})) {
        throw ("VS Code CLI not found at {0}; cannot install extensions." -f ${codeCmd})
    }
    # Bounded wait so a wedged CLI under a Session-0 WinRM context cannot hang the
    # whole run (same failure mode the installer guards against). -NoNewWindow (not
    # -WindowStyle Hidden) because stdout/stderr redirection needs CreateProcess.
    ${extTimeoutMs} = 5 * 60 * 1000
    function Invoke-CodeCli {
        param([string[]]${CliArgs}, [string]${OutLog}, [string]${Tag})
        ${proc} = Start-Process -FilePath ${codeCmd} -ArgumentList ${CliArgs} -PassThru -NoNewWindow `
            -RedirectStandardOutput ${OutLog} -RedirectStandardError ("{0}.err" -f ${OutLog})
        if (-not ${proc}) { throw ("Start-Process returned no object for code CLI ({0})" -f ${Tag}) }
        if (-not ${proc}.WaitForExit(${extTimeoutMs})) {
            try { & taskkill.exe /T /F /PID $(${proc}.Id) 2>$null | Out-Null } catch {}
            try { ${proc}.Kill() } catch {}
            throw ("VS Code CLI timed out ({0}); process tree killed. See {1}" -f ${Tag}, ${OutLog})
        }
        try { ${proc}.Refresh() } catch {}
        return ${proc}.ExitCode
    }

    # ms-python.python is listed first (debugpy pairs with it); order is not critical.
    ${vsixNames} = @(
        'ms-python.python-2026.4.0-win32-x64.vsix',
        'ms-python.debugpy-2026.6.0-win32-x64.vsix'
    )
    foreach (${vsixName} in ${vsixNames}) {
        ${vsixPath} = Join-Path ${AssetsRoot} ${vsixName}
        if (-not (Test-Path -LiteralPath ${vsixPath})) {
            throw ("Bundled VS Code extension not found: {0}" -f ${vsixPath})
        }
        ${vsixPath} = (Resolve-Path -LiteralPath ${vsixPath}).Path
        ${extOut}   = Join-Path ${logDir} ("vscode-ext-{0}.log" -f ${vsixName})
        Write-VscodeLog ("Installing extension (offline): {0}" -f ${vsixName})
        ${rc} = Invoke-CodeCli -CliArgs @('--install-extension', ${vsixPath}, '--force') -OutLog ${extOut} -Tag ${vsixName}
        Write-VscodeLog ("  {0} exit code: {1}" -f ${vsixName}, ${rc})
    }

    # Confirm both are registered in this user's profile.
    ${listOut} = Join-Path ${logDir} 'vscode-ext-list.log'
    ${null} = Invoke-CodeCli -CliArgs @('--list-extensions', '--show-versions') -OutLog ${listOut} -Tag 'list-extensions'
    ${installedExts} = (Get-Content -LiteralPath ${listOut} -ErrorAction SilentlyContinue) -join "`n"
    foreach (${want} in 'ms-python.python', 'ms-python.debugpy') {
        if (${installedExts} -match [regex]::Escape(${want})) {
            Write-VscodeLog ("Extension present: {0}" -f ${want})
        } else {
            throw ("VS Code extension not present after install: {0} (see {1})" -f ${want}, ${listOut})
        }
    }

    Write-VscodeLog "VS Code installation completed successfully"
    exit 0
}
catch {
    ${errorMsg} = "VSCode installation failed: $_"
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
