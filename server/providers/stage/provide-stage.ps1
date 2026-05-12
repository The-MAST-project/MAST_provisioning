param(
    [string]${AssetsRoot} = ".",
    [string]${InstallRoot} = "C:\Program Files\Stage"
)

${ErrorActionPreference} = "Stop"
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "stage-install.log"

function Write-StageLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-stage.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    ${installerPath} = Join-Path ${AssetsRoot} "xilab-1.20.19-win32_win64.exe"
    if (-not (Test-Path ${installerPath})) {
        throw "Stage installer not found at ${installerPath}"
    }

    # /S = NSIS silent; /NCRC skips CRC verification which can stall some NSIS builds.
    # stdout/stderr are redirected so any installer output is captured in the session log.
    Write-StageLog ("Running Stage installer: {0} /S /NCRC" -f ${installerPath})
    ${stdoutLog} = Join-Path ${logDir} "stage-install-stdout.log"
    ${stderrLog} = Join-Path ${logDir} "stage-install-stderr.log"
    ${p} = Start-Process -FilePath ${installerPath} -ArgumentList '/S', '/NCRC' -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput ${stdoutLog} -RedirectStandardError ${stderrLog}
    Write-StageLog ("Installer PID: {0}; waiting up to 600s..." -f ${p}.Id)
    ${finished} = ${p}.WaitForExit(600000)
    try { ${p}.Refresh() } catch {}

    # Append captured output to main log regardless of outcome.
    foreach (${cap} in @(${stdoutLog}, ${stderrLog})) {
        if (Test-Path -LiteralPath ${cap}) {
            ${lines} = Get-Content -LiteralPath ${cap} -ErrorAction SilentlyContinue
            if (${lines}) { ${lines} | ForEach-Object { Write-StageLog ("installer: {0}" -f $_) } }
        }
    }

    if (-not ${finished}) {
        # Snapshot child processes for diagnostics before killing.
        try {
            ${children} = Get-CimInstance Win32_Process -Filter "ParentProcessId=${($p.Id)}" -ErrorAction SilentlyContinue
            if (${children}) {
                Write-StageLog ("Child processes at timeout: {0}" -f (($children | ForEach-Object { "$($_.Name) (pid $($_.ProcessId))" }) -join ', '))
            } else {
                Write-StageLog "No child processes found under installer PID at timeout."
            }
        } catch { Write-StageLog ("Child-process query failed: {0}" -f $_) }
        try { ${p}.Kill() } catch {}
        Write-StageLog "XILab installer timed out after 600s -- process killed."
        throw "XILab installer timed out (600s). Check for a blocked dialog in session 0."
    }
    Write-StageLog ("Installer exited. ExitCode={0}" -f ${p}.ExitCode)
    if ($null -ne ${p}.ExitCode -and ${p}.ExitCode -ne 0) {
        throw ("XILab installer failed with exit code {0}" -f ${p}.ExitCode)
    }

    # NSIS silent installers sometimes exit before all files are written; give it a moment.
    Start-Sleep -Seconds 5

    Write-StageLog "Searching for xilab.exe in Program Files..."
    ${stageExe} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
        -Recurse -Filter 'xilab.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not ${stageExe}) {
        throw "xilab.exe not found after installation - installer may have failed silently"
    }

    Write-StageLog ("Stage installation completed successfully: {0}" -f ${stageExe})
    exit 0
}
catch {
    ${errorMsg} = ("Stage installation failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
