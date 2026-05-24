param(
    [string]${AssetsRoot}        = ".",
    [string]${EnabledCollectors} = "cpu,cs,logical_disk,net,os,service,system,textfile",
    [int]   ${ListenPort}        = 9182
)

${ErrorActionPreference} = "Stop"

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}

${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "windows-exporter-monitoring-install.log"

function Write-ExpLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-windows-exporter-monitoring.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# Upstream ships fix-perf-counters.ps1 alongside the MSI because the
# windows_exporter PerfData collectors silently miss series when perf counters
# are corrupted. Run it first if present; treat failure as non-fatal so the MSI
# install still proceeds and gets logged.
${fixPerf} = Join-Path ${AssetsRoot} 'fix-perf-counters.ps1'
if (Test-Path -LiteralPath ${fixPerf}) {
    Write-ExpLog ("Running perf-counter repair: {0}" -f ${fixPerf})
    try {
        & powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -File ${fixPerf} 2>&1 |
            ForEach-Object { Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[perf] {0}" -f $_) }
        Write-ExpLog ("fix-perf-counters.ps1 exit code: {0}" -f ${LASTEXITCODE})
    } catch {
        Write-ExpLog ("[WARN] fix-perf-counters.ps1 threw: {0}" -f $_)
    }
} else {
    Write-ExpLog ("fix-perf-counters.ps1 not present under {0}; skipping perf-counter repair." -f ${AssetsRoot})
}

# Match mastw: Prometheus windows_exporter listening on 9182 so the unit can
# be scraped by the fleet observability stack. MSI installs as a LocalSystem
# auto-start service named 'windows_exporter'.
try {
    ${msiCandidates} = @(Get-ChildItem -Path ${AssetsRoot} -Filter 'windows_exporter-*-amd64.msi' -File -ErrorAction SilentlyContinue)
    if (${msiCandidates}.Count -eq 0) {
        throw ("windows_exporter MSI not found under {0}. Drop windows_exporter-<ver>-amd64.msi into the provider's assets/." -f ${AssetsRoot})
    }
    ${msiPath} = ${msiCandidates}[0].FullName
    Write-ExpLog ("Using installer: {0}" -f ${msiPath})

    # Idempotency: if service already exists, skip the install but still ensure
    # the firewall rule + autostart shape are correct.
    ${existing} = Get-Service -Name 'windows_exporter' -ErrorAction SilentlyContinue
    if ($null -eq ${existing}) {
        ${msiArgs} = @(
            '/i', ('"{0}"' -f ${msiPath}),
            '/qn',
            '/norestart',
            ('ENABLED_COLLECTORS="{0}"' -f ${EnabledCollectors}),
            ('LISTEN_PORT={0}' -f ${ListenPort})
        )
        Write-ExpLog ("msiexec {0}" -f (${msiArgs} -join ' '))
        ${p} = Start-Process -FilePath 'msiexec.exe' -ArgumentList ${msiArgs} -Wait -PassThru -WindowStyle Hidden
        ${rc} = ${p}.ExitCode
        Write-ExpLog ("msiexec exit code: {0}" -f ${rc})
        if (${rc} -ne 0 -and ${rc} -ne 3010) {
            throw ("msiexec failed with exit code {0}" -f ${rc})
        }
    } else {
        Write-ExpLog "windows_exporter service already present; skipping MSI install."
    }

    Set-Service -Name 'windows_exporter' -StartupType Automatic -ErrorAction Stop
    Start-Service -Name 'windows_exporter' -ErrorAction SilentlyContinue

    ${fwRuleName} = ("MAST windows_exporter (TCP {0})" -f ${ListenPort})
    if (-not (Get-NetFirewallRule -DisplayName ${fwRuleName} -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName ${fwRuleName} -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort ${ListenPort} -Profile Any -ErrorAction Stop | Out-Null
        Write-ExpLog ("Firewall rule created: {0}" -f ${fwRuleName})
    } else {
        Write-ExpLog ("Firewall rule already exists: {0}" -f ${fwRuleName})
    }

    ${smokeDir} = Get-MastSmokeDir
    New-Item -ItemType Directory -Path ${smokeDir} -Force | Out-Null
    Set-Content -LiteralPath (Join-Path ${smokeDir} 'windows-exporter-smoke.txt') -Encoding UTF8 -Value 'windows_exporter_ok'

    Write-ExpLog "windows_exporter provisioning completed successfully."
    exit 0
}
catch {
    ${errorMsg} = ("windows_exporter provisioning failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
