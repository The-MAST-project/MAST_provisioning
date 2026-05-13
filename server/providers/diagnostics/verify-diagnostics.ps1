#requires -Version 5.1
<#
.SYNOPSIS
  Runtime verification: ASCOM diagnostics, app launch checks, PHD2 JSON-RPC port, MAST_unit heartbeat.

.NOTES
  - PHD2 must be registered as an NSSM service (provide-phd2.ps1) before this runs.
  - MAST_unit must be registered as an NSSM service (provide-mast.ps1) before this runs.
  - MAST_unit heartbeat port: set $MastUnitPort below to match the unit's HTTP listener port.
  - ASCOM Diagnostics tool path: adjust $AscomDiagExe if the Platform version differs.
#>
[CmdletBinding()]
param(
    [int]${MastUnitPort} = 5000,
    [int]${Phd2RpcPort}  = 4400
)

${ErrorActionPreference} = 'Stop'

${logRoot}    = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'logs'
${verifyLog}  = Join-Path ${logRoot} 'verify\diagnostics-verify.log'
${smokeFile}  = Join-Path ${logRoot} 'smoke\diagnostics-smoke.txt'
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${verifyLog}) -ErrorAction SilentlyContinue
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${smokeFile}) -ErrorAction SilentlyContinue

${results} = @()
${failCount} = 0

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
        'C:\Program Files\ASCOM\Platform 6\Tools\Diagnostics\ASCOM.Diagnostics.exe',
        'C:\Program Files (x86)\ASCOM\Platform 6\Tools\Diagnostics\ASCOM.Diagnostics.exe',
        'C:\Program Files\ASCOM\Diagnostics\ASCOM.Diagnostics.exe'
    )
    ${ascomDiagExe} = $null
    foreach (${c} in ${ascomDiagCandidates}) {
        if (Test-Path -LiteralPath ${c}) { ${ascomDiagExe} = ${c}; break }
    }
    if ($null -eq ${ascomDiagExe}) {
        Add-DiagResult -Name 'ASCOM-diagnostics' -Ok $false -Detail 'ASCOM.Diagnostics.exe not found in known paths'
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
} catch {
    Add-DiagResult -Name 'XILabs-launch' -Ok $false -Detail ("exception: {0}" -f $_.Exception.Message)
}

# --- 6. PHD2 JSON-RPC server alive (TCP port 4400) ---
try {
    ${phd2Svc} = Get-Service -Name 'PHD2' -ErrorAction SilentlyContinue
    if ($null -ne ${phd2Svc} -and ${phd2Svc}.Status -ne 'Running') {
        Start-Service -Name 'PHD2' -ErrorAction SilentlyContinue
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
    Add-DiagResult -Name 'PHD2-rpc-port' -Ok ${tcpOk} -Detail ("port={0} connected={1}" -f ${Phd2RpcPort}, ${tcpOk})
} catch {
    Add-DiagResult -Name 'PHD2-rpc-port' -Ok $false -Detail ("exception: {0}" -f $_.Exception.Message)
}

# --- 7. MAST_unit HTTP heartbeat ---
try {
    ${mastSvc} = Get-Service -Name 'MAST_unit' -ErrorAction SilentlyContinue
    if ($null -ne ${mastSvc} -and ${mastSvc}.Status -ne 'Running') {
        Start-Service -Name 'MAST_unit' -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
    }
    ${heartbeatUrl} = ("http://127.0.0.1:{0}/heartbeat" -f ${MastUnitPort})
    ${resp} = $null
    try {
        ${resp} = Invoke-WebRequest -Uri ${heartbeatUrl} -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    } catch {}
    ${hbOk} = $null -ne ${resp} -and ${resp}.StatusCode -ge 200 -and ${resp}.StatusCode -lt 300
    Add-DiagResult -Name 'MAST_unit-heartbeat' -Ok ${hbOk} -Detail ("url={0} status={1}" -f ${heartbeatUrl}, $(if ($null -ne ${resp}) { ${resp}.StatusCode } else { 'no-response' }))
} catch {
    Add-DiagResult -Name 'MAST_unit-heartbeat' -Ok $false -Detail ("exception: {0}" -f $_.Exception.Message)
}

# --- Summary ---
${summary} = ("diagnostics: {0} check(s) failed" -f ${failCount})
${summary} | Out-File -FilePath ${verifyLog} -Encoding UTF8 -Append
Write-Host ${summary}

if (${failCount} -gt 0) {
    exit 1
}

Set-Content -Path ${smokeFile} -Value 'diagnostics_ok' -Encoding UTF8
exit 0
