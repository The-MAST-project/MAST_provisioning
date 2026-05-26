param(
    [string]${AssetsRoot}        = ".",
    # Default collector set. This is the original broad MAST observability
    # list that lived in server/providers/monitoring/assets/install-windows_exporter.ps1
    # (provider renamed/refactored 2026-05-24 in commit 05175b9, which
    # silently slimmed this list and dropped 'cpu_info'). Restored here
    # 2026-05-26, with one change: the 'cs' (computer system) collector
    # has been deprecated/removed in windows_exporter >= 0.31.x. Leaving
    # 'cs' in makes the service crash with 'unknown collector cs' and
    # restart-loop forever (run #12 confirmed via service event log:
    #   couldn't enable collectors err="unknown collector cs"
    # ). Equivalent data lives in 'cpu_info', 'os', and 'system'.
    [string]${EnabledCollectors} = "cpu,cpu_info,logical_disk,physical_disk,memory,net,os,process,service,system,tcp,textfile,thermalzone,time,scheduled_task,terminal_services,smbclient,smb,dns,dhcp,iis,logon",
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

    # Start the service and verify it actually reached Running + bound the
    # listen port. Previous version used Start-Service -ErrorAction
    # SilentlyContinue and marked the provider successful regardless --
    # which is how run #11 ended up with msiexec=0 + smoke marker written
    # but no service on port 9182 (verify caught it but the provider lied).
    # Surface the real failure with the most useful diagnostics we can
    # collect on the unit: service state, ServicesPipeTimeout-style hangs,
    # last few Application/System event log entries for the service.
    try {
        Start-Service -Name 'windows_exporter' -ErrorAction Stop
    } catch {
        Write-ExpLog ("Start-Service threw: {0}" -f $_.Exception.Message)
        # Don't throw yet -- fall through to the post-start poll; some
        # transient errors clear on their own and the service ends up
        # Running anyway.
    }

    # Poll for Running + port bound. windows_exporter starts in <5s when
    # healthy, but allow 60s for first-boot perf-counter rebuild after the
    # fix-perf-counters.ps1 step above.
    ${runningOk} = $false
    ${portOk}    = $false
    ${deadline}  = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt ${deadline}) {
        ${svc} = Get-Service -Name 'windows_exporter' -ErrorAction SilentlyContinue
        if (${svc}.Status -eq 'Running') { ${runningOk} = $true }
        ${portOk} = [bool](Get-NetTCPConnection -State Listen -LocalPort ${ListenPort} -ErrorAction SilentlyContinue)
        if (${runningOk} -and ${portOk}) { break }
        Start-Sleep -Seconds 3
    }

    if (-not (${runningOk} -and ${portOk})) {
        Write-ExpLog ("FAIL: service Running={0} port{1}Bound={2}" -f ${runningOk}, ${ListenPort}, ${portOk})
        ${svc} = Get-Service -Name 'windows_exporter' -ErrorAction SilentlyContinue
        if ($null -ne ${svc}) {
            Write-ExpLog ("service Name={0} Status={1} StartType={2}" -f ${svc}.Name, ${svc}.Status, ${svc}.StartType)
        } else {
            Write-ExpLog "service 'windows_exporter' is not registered."
        }
        # WMI status code: 0 = OK, anything else explains the failure.
        try {
            ${wmi} = Get-CimInstance -ClassName Win32_Service -Filter "Name='windows_exporter'" -ErrorAction Stop
            if ($null -ne ${wmi}) {
                Write-ExpLog ("Win32_Service Name={0} State={1} StartMode={2} PathName={3} ExitCode={4} ServiceSpecificExitCode={5}" `
                    -f ${wmi}.Name, ${wmi}.State, ${wmi}.StartMode, ${wmi}.PathName, ${wmi}.ExitCode, ${wmi}.ServiceSpecificExitCode)
            }
        } catch { Write-ExpLog ("Win32_Service query failed: {0}" -f $_.Exception.Message) }

        Write-ExpLog "--- last 20 System event log entries for the windows_exporter service ---"
        try {
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager' } -MaxEvents 50 -ErrorAction Stop |
                Where-Object { $_.Message -match 'windows_exporter' } |
                Select-Object -First 20 |
                ForEach-Object { Write-ExpLog ("  [{0}] {1}: {2}" -f $_.TimeCreated, $_.LevelDisplayName, ($_.Message -replace "`r?`n", ' / ')) }
        } catch { Write-ExpLog ("System log query failed: {0}" -f $_.Exception.Message) }

        Write-ExpLog "--- last 20 Application event log entries for the windows_exporter service ---"
        try {
            Get-WinEvent -FilterHashtable @{ LogName = 'Application' } -MaxEvents 200 -ErrorAction Stop |
                Where-Object { $_.ProviderName -match 'windows_exporter' -or $_.Message -match 'windows_exporter' } |
                Select-Object -First 20 |
                ForEach-Object { Write-ExpLog ("  [{0}] {1} (src={2}): {3}" -f $_.TimeCreated, $_.LevelDisplayName, $_.ProviderName, ($_.Message -replace "`r?`n", ' / ')) }
        } catch { Write-ExpLog ("Application log query failed: {0}" -f $_.Exception.Message) }

        # PathName tells us where windows_exporter.exe lives -- include a
        # quick spot-check that the binary exists, in case the MSI shifted
        # its install layout in some version.
        if (${wmi} -and ${wmi}.PathName) {
            ${binPath} = (${wmi}.PathName -split '"')[1]
            if (-not ${binPath}) { ${binPath} = (${wmi}.PathName -split ' ')[0] }
            Write-ExpLog ("Service binary path: {0}  exists={1}" -f ${binPath}, (Test-Path -LiteralPath ${binPath}))
        }

        throw ("windows_exporter service did not reach Running+port-bound within 60s (Running={0}, port{1}Bound={2})." `
                -f ${runningOk}, ${ListenPort}, ${portOk})
    }
    Write-ExpLog ("windows_exporter healthy: Status=Running listening on TCP {0}." -f ${ListenPort})

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
