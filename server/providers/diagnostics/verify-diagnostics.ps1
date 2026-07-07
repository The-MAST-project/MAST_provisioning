#requires -Version 5.1
<#
.SYNOPSIS
  Runtime verification: ASCOM diagnostics, app launch checks, PHD2 JSON-RPC port, MAST_unit heartbeat.

.NOTES
  - PHD2 must be registered as an NSSM service (provide-phd2.ps1) before this runs.
  - MAST_unit must be registered as an NSSM service (provide-mast.ps1) before this runs.
  - MAST_unit heartbeat port: set $MastUnitPort below to match the unit's HTTP listener port.
  - ASCOM Diagnostics tool: searched recursively under C:\Program Files\ASCOM (Platform 6 and 7 supported).
#>
[CmdletBinding()]
param(
    [int]${MastUnitPort} = 8000,
    [int]${Phd2RpcPort}  = 4400
)

${ErrorActionPreference} = 'Stop'

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts predate it and probe optional properties
${verifyLog} = Get-MastVerifyLog -Module 'diagnostics'

${results} = @()
${failCount} = 0

${hostsFile} = Join-Path ${env:SystemRoot} 'System32\drivers\etc\hosts'
${hostsContent} = Get-Content -LiteralPath ${hostsFile} -ErrorAction SilentlyContinue
${isVmTestRun} = $false
if (${hostsContent}) {
    foreach (${line} in ${hostsContent}) {
        if (${line} -match '# MAST-VM-TEST-ONLY') { ${isVmTestRun} = $true; break }
    }
}

function Add-DiagResult {
    param([string]${Name}, [bool]${Ok}, [string]${Detail})
    ${status} = if (${Ok}) { '[OK]  ' } else { '[FAIL]' }
    ${line} = ("{0} {1}: {2}" -f ${status}, ${Name}, ${Detail})
    ${line} | Out-File -FilePath ${verifyLog} -Encoding UTF8 -Append
    Write-Host ${line}
    if (-not ${Ok}) { $script:failCount++ }
}

${null} = Set-Content -Path ${verifyLog} -Value ("[{0}] diagnostics verify-diagnostics.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8

# --- 1. ASCOM registry key + at least one device profile subkey ---
try {
    ${ascomKey} = 'HKLM:\SOFTWARE\ASCOM'
    ${ascomWow} = 'HKLM:\SOFTWARE\WOW6432Node\ASCOM'
    ${ascomBase} = $null
    if (Test-Path -LiteralPath ${ascomKey}) { ${ascomBase} = ${ascomKey} }
    elseif (Test-Path -LiteralPath ${ascomWow}) { ${ascomBase} = ${ascomWow} }
    if ($null -eq ${ascomBase}) {
        Add-DiagResult -Name 'ASCOM-registry' -Ok $false -Detail 'ASCOM registry key not found'
    } else {
        ${subs} = @(Get-ChildItem -LiteralPath ${ascomBase} -ErrorAction SilentlyContinue)
        if (${subs}.Count -gt 0) {
            Add-DiagResult -Name 'ASCOM-registry' -Ok $true -Detail ("key={0} subkeys={1}" -f ${ascomBase}, ${subs}.Count)
        } else {
            Add-DiagResult -Name 'ASCOM-registry' -Ok $false -Detail ("ASCOM key present but has no device profile subkeys: {0}" -f ${ascomBase})
        }
    }
} catch {
    Add-DiagResult -Name 'ASCOM-registry' -Ok $false -Detail ("exception: {0}" -f $_.Exception.Message)
}

# --- 2. ASCOM Diagnostics tool launches without error ---
try {
    ${ascomDiagCandidates} = @(
        'C:\Program Files (x86)\ASCOM\Platform\Tools\ASCOM Diagnostics.exe',
        'C:\Program Files\ASCOM\Platform\Tools\ASCOM Diagnostics.exe',
        'C:\Program Files (x86)\ASCOM\Platform 7\Tools\Diagnostics\ASCOM Diagnostics.exe',
        'C:\Program Files\ASCOM\Platform 7\Tools\Diagnostics\ASCOM Diagnostics.exe',
        'C:\Program Files (x86)\ASCOM\Platform 6\Tools\Diagnostics\ASCOM Diagnostics.exe',
        'C:\Program Files\ASCOM\Platform 6\Tools\Diagnostics\ASCOM Diagnostics.exe'
    )
    ${ascomDiagExe} = $null
    foreach (${c} in ${ascomDiagCandidates}) {
        if (Test-Path -LiteralPath ${c}) { ${ascomDiagExe} = ${c}; break }
    }
    if ($null -eq ${ascomDiagExe}) {
        ${found1} = Get-ChildItem -Path 'C:\Program Files\ASCOM', 'C:\Program Files (x86)\ASCOM', `
            'C:\Program Files\ASCOM Platform 7', 'C:\Program Files (x86)\ASCOM Platform 7' `
            -Recurse -Filter 'ASCOM Diagnostics.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (${found1}) { ${ascomDiagExe} = ${found1}.FullName }
    }
    if ($null -eq ${ascomDiagExe}) {
        Add-DiagResult -Name 'ASCOM-diagnostics' -Ok $false -Detail 'ASCOM Diagnostics.exe not found in known paths'
    } else {
        ${p} = Start-Process -FilePath ${ascomDiagExe} -PassThru -WindowStyle Hidden -ErrorAction Stop
        ${started} = $null -ne ${p} -and ${p}.Id -gt 0
        Start-Sleep -Seconds 3
        try {
            if (-not ${p}.HasExited) { ${p}.Kill() }
        } catch {}
        Add-DiagResult -Name 'ASCOM-diagnostics' -Ok ${started} -Detail ("exe={0} pid={1}" -f ${ascomDiagExe}, $(if (${started}) { ${p}.Id } else { 'none' }))
    }
} catch {
    Add-DiagResult -Name 'ASCOM-diagnostics' -Ok $false -Detail ("exception: {0}" -f $_.Exception.Message)
}

# --- 3. ASIStudio launches ---
try {
    ${asiCandidates} = @(
        'C:\Program Files\ASIStudio\ASIStudio.exe',
        'C:\Program Files (x86)\ASIStudio\ASIStudio.exe'
    )
    ${asiExe} = $null
    foreach (${c} in ${asiCandidates}) {
        if (Test-Path -LiteralPath ${c}) { ${asiExe} = ${c}; break }
    }
    if ($null -eq ${asiExe}) {
        ${found2} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
            -Recurse -Filter 'ASIStudio.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (${found2}) { ${asiExe} = ${found2}.FullName }
    }
    if ($null -eq ${asiExe}) {
        Add-DiagResult -Name 'ASIStudio-launch' -Ok $false -Detail 'ASIStudio.exe not found'
    } else {
        ${p} = Start-Process -FilePath ${asiExe} -PassThru -WindowStyle Hidden -ErrorAction Stop
        ${started} = $null -ne ${p} -and ${p}.Id -gt 0
        Start-Sleep -Seconds 5
        try { if (-not ${p}.HasExited) { ${p}.Kill() } } catch {}
        Add-DiagResult -Name 'ASIStudio-launch' -Ok ${started} -Detail ("exe={0} pid={1}" -f ${asiExe}, $(if (${started}) { ${p}.Id } else { 'none' }))
    }
} catch {
    Add-DiagResult -Name 'ASIStudio-launch' -Ok $false -Detail ("exception: {0}" -f $_.Exception.Message)
}

# --- 4. PWI4 launches ---
try {
    ${pwiCandidates} = @(
        'C:\Program Files\PlaneWave Instruments\PlaneWave Interface 4\PWI4.exe',
        'C:\Program Files (x86)\PlaneWave Instruments\PlaneWave Interface 4\PWI4.exe'
    )
    ${pwiExe} = $null
    foreach (${c} in ${pwiCandidates}) {
        if (Test-Path -LiteralPath ${c}) { ${pwiExe} = ${c}; break }
    }
    if ($null -eq ${pwiExe}) {
        ${found3} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
            -Recurse -Filter 'PWI4.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (${found3}) { ${pwiExe} = ${found3}.FullName }
    }
    if ($null -eq ${pwiExe}) {
        Add-DiagResult -Name 'PWI4-launch' -Ok $false -Detail 'PWI4.exe not found'
    } else {
        ${p} = Start-Process -FilePath ${pwiExe} -PassThru -WindowStyle Hidden -ErrorAction Stop
        ${started} = $null -ne ${p} -and ${p}.Id -gt 0
        Start-Sleep -Seconds 5
        try { if (-not ${p}.HasExited) { ${p}.Kill() } } catch {}
        Add-DiagResult -Name 'PWI4-launch' -Ok ${started} -Detail ("exe={0} pid={1}" -f ${pwiExe}, $(if (${started}) { ${p}.Id } else { 'none' }))
    }
} catch {
    Add-DiagResult -Name 'PWI4-launch' -Ok $false -Detail ("exception: {0}" -f $_.Exception.Message)
}

# --- 5. XILabs (xilab.exe) launches ---
try {
    ${stageSmokeFile} = Get-MastSmokeMarker -Module 'stage'
    if (-not (Test-Path -LiteralPath ${stageSmokeFile})) {
        Add-DiagResult -Name 'XILabs-launch' -Ok $true -Detail 'stage module not provisioned - skipped'
    } else {
    ${xlabCandidates} = @(
        'C:\Program Files\XILab\XILab.exe',
        'C:\Program Files (x86)\XILab\XILab.exe'
    )
    ${xlabExe} = $null
    foreach (${c} in ${xlabCandidates}) {
        if (Test-Path -LiteralPath ${c}) { ${xlabExe} = ${c}; break }
    }
    if ($null -eq ${xlabExe}) {
        ${found4} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
            -Recurse -Filter 'xilab.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (${found4}) { ${xlabExe} = ${found4}.FullName }
    }
    if ($null -eq ${xlabExe}) {
        Add-DiagResult -Name 'XILabs-launch' -Ok $false -Detail 'xilab.exe not found'
    } else {
        ${p} = Start-Process -FilePath ${xlabExe} -PassThru -WindowStyle Hidden -ErrorAction Stop
        ${started} = $null -ne ${p} -and ${p}.Id -gt 0
        Start-Sleep -Seconds 5
        try { if (-not ${p}.HasExited) { ${p}.Kill() } } catch {}
        Add-DiagResult -Name 'XILabs-launch' -Ok ${started} -Detail ("exe={0} pid={1}" -f ${xlabExe}, $(if (${started}) { ${p}.Id } else { 'none' }))
    }
    } # end else (stage provisioned)
} catch {
    Add-DiagResult -Name 'XILabs-launch' -Ok $false -Detail ("exception: {0}" -f $_.Exception.Message)
}

# --- 6. PHD2 JSON-RPC server alive (TCP port 4400) ---
try {
    ${phd2Svc} = Get-Service -Name 'mast-phd2' -ErrorAction SilentlyContinue
    if ($null -ne ${phd2Svc} -and ${phd2Svc}.Status -ne 'Running') {
        Start-Service -Name 'mast-phd2' -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
    }
    ${tcpOk} = $false
    ${tcpClient} = New-Object System.Net.Sockets.TcpClient
    try {
        ${ar} = ${tcpClient}.BeginConnect('127.0.0.1', ${Phd2RpcPort}, $null, $null)
        ${waited} = ${ar}.AsyncWaitHandle.WaitOne(10000)
        if (${waited}) {
            ${tcpClient}.EndConnect(${ar})
            ${tcpOk} = $true
        }
    } catch {}
    finally { ${tcpClient}.Close() }
    # PHD2 only binds its JSON-RPC port after connecting to a camera/guide scope.
    # In VM test mode (no hardware), treat port not bound as a warning only.
    if (${tcpOk}) {
        Add-DiagResult -Name 'PHD2-rpc-port' -Ok $true -Detail ("port={0} connected={1}" -f ${Phd2RpcPort}, ${tcpOk})
    } elseif (${isVmTestRun}) {
        ${line} = ("[WARN] PHD2-rpc-port: port={0} not bound (VM test mode - no hardware)" -f ${Phd2RpcPort})
        ${line} | Out-File -FilePath ${verifyLog} -Encoding UTF8 -Append
        Write-Host ${line}
    } else {
        Add-DiagResult -Name 'PHD2-rpc-port' -Ok $false -Detail ("port={0} not bound (requires connected camera/guide scope)" -f ${Phd2RpcPort})
    }
} catch {
    Add-DiagResult -Name 'PHD2-rpc-port' -Ok $false -Detail ("exception: {0}" -f $_.Exception.Message)
}

# --- 7. mast-unit HTTP heartbeat ---
try {
    ${mastSvc} = Get-Service -Name 'mast-unit' -ErrorAction SilentlyContinue
    if ($null -ne ${mastSvc} -and ${mastSvc}.Status -ne 'Running') {
        Start-Service -Name 'mast-unit' -ErrorAction SilentlyContinue
    }
    ${heartbeatUrl} = ("http://127.0.0.1:{0}/mast/api/v1/unit/status" -f ${MastUnitPort})
    ${resp} = $null
    # Poll up to 60s to allow for service startup after a recent restart.
    ${deadline} = (Get-Date).AddSeconds(60)
    while ($null -eq ${resp} -and (Get-Date) -lt ${deadline}) {
        try {
            ${resp} = Invoke-WebRequest -Uri ${heartbeatUrl} -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        } catch {
            Start-Sleep -Seconds 3
        }
    }
    ${hbOk} = $null -ne ${resp} -and ${resp}.StatusCode -ge 200 -and ${resp}.StatusCode -lt 300
    Add-DiagResult -Name 'mast-unit-heartbeat' -Ok ${hbOk} -Detail ("url={0} status={1}" -f ${heartbeatUrl}, $(if ($null -ne ${resp}) { ${resp}.StatusCode } else { 'no-response' }))
} catch {
    Add-DiagResult -Name 'mast-unit-heartbeat' -Ok $false -Detail ("exception: {0}" -f $_.Exception.Message)
}

# --- Summary ---
${summary} = ("diagnostics: {0} check(s) failed" -f ${failCount})
${summary} | Out-File -FilePath ${verifyLog} -Encoding UTF8 -Append
Write-Host ${summary}

if (${failCount} -gt 0) {
    exit 1
}

Write-MastSmokeOk -Module 'diagnostics' | Out-Null
exit 0
