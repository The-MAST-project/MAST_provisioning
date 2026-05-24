param(
    [string]${AssetsRoot} = ".",
    [string]${InstallRoot} = "C:\Program Files\Wireshark"
)

${ErrorActionPreference} = "Stop"
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "wireshark-install.log"

function Write-WiresharkLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-wireshark.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    ${installerPath} = Join-Path ${AssetsRoot} "Wireshark-4.6.0-x64.exe"
    if (-not (Test-Path ${installerPath})) {
        throw "Wireshark installer not found at ${installerPath}"
    }

    Write-WiresharkLog ("Running Wireshark installer: {0} /S" -f ${installerPath})
    ${stderrLog} = Join-Path ${logDir} "wireshark-install-stderr.log"
    ${stdoutLog} = Join-Path ${logDir} "wireshark-install-stdout.log"
    ${p} = Start-Process -FilePath ${installerPath} -ArgumentList @('/S', ("/D={0}" -f ${InstallRoot})) -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput ${stdoutLog} -RedirectStandardError ${stderrLog}
    Write-WiresharkLog ("Installer PID: {0}; waiting up to 300s..." -f ${p}.Id)
    ${finished} = ${p}.WaitForExit(300000)
    try { ${p}.Refresh() } catch {}
    if (-not ${finished}) {
        try { ${p}.Kill() } catch {}
        throw "Wireshark installer timed out after 300s (process killed)."
    }
    Write-WiresharkLog ("Wireshark installer exited. ExitCode={0}" -f ${p}.ExitCode)
    if (Test-Path -LiteralPath ${stdoutLog}) {
        Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value '--- installer stdout ---'
        Get-Content -LiteralPath ${stdoutLog} -ErrorAction SilentlyContinue | Add-Content -LiteralPath ${logFile} -Encoding UTF8
    }
    if (Test-Path -LiteralPath ${stderrLog}) {
        Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value '--- installer stderr ---'
        Get-Content -LiteralPath ${stderrLog} -ErrorAction SilentlyContinue | Add-Content -LiteralPath ${logFile} -Encoding UTF8
    }
    if ($null -ne ${p}.ExitCode -and ${p}.ExitCode -ne 0) {
        throw ("Wireshark installer exited with code {0}" -f ${p}.ExitCode)
    }

    ${wiresharkExe} = Join-Path ${InstallRoot} "Wireshark.exe"
    if (-not (Test-Path ${wiresharkExe})) {
        throw ("Wireshark executable not found after installation at {0}" -f ${wiresharkExe})
    }

    # --- Npcap (optional, mastw ships it) ---
    # Match mastw: install Npcap so live packet capture works. The Npcap
    # installer is shipped under assets/ if available; if absent, log a
    # warning and continue (Wireshark itself works without Npcap, captures
    # just need to be on .pcap files).
    ${npcapCandidates} = @(Get-ChildItem -Path ${AssetsRoot} -Filter 'npcap-*.exe' -File -ErrorAction SilentlyContinue)
    if (${npcapCandidates}.Count -eq 0) {
        Write-WiresharkLog "[WARN] No npcap-*.exe under AssetsRoot; skipping Npcap install (matches mastw's npcapwatchdog scheduled task purpose)."
    } else {
        ${npcapPath} = ${npcapCandidates}[0].FullName
        Write-WiresharkLog ("Running Npcap installer: {0}" -f ${npcapPath})
        # Npcap supports an NSIS-style silent install with feature flags:
        # /loopback_support=yes - capture from loopback adapter (matches mastw)
        # /winpcap_mode=yes     - WinPcap compat for legacy callers
        # /admin_only=no        - allow non-admin Wireshark sessions
        ${npcapArgs} = @('/S', '/loopback_support=yes', '/winpcap_mode=yes', '/admin_only=no')
        ${pn} = Start-Process -FilePath ${npcapPath} -ArgumentList ${npcapArgs} -PassThru -WindowStyle Hidden
        ${ok} = ${pn}.WaitForExit(300000)
        try { ${pn}.Refresh() } catch {}
        if (-not ${ok}) {
            try { ${pn}.Kill() } catch {}
            Write-WiresharkLog "[WARN] Npcap installer timed out after 300s; continuing without."
        } else {
            Write-WiresharkLog ("Npcap installer exited. ExitCode={0}" -f ${pn}.ExitCode)
            ${npcapSvc} = Get-Service -Name 'npcap' -ErrorAction SilentlyContinue
            if ($null -eq ${npcapSvc}) {
                Write-WiresharkLog "[WARN] Npcap service not registered after install."
            } else {
                Write-WiresharkLog ("Npcap service state: {0}" -f ${npcapSvc}.Status)
            }
        }
    }

    Write-WiresharkLog "Wireshark installation completed successfully."
    exit 0
}
catch {
    ${errorMsg} = ("Wireshark installation failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
