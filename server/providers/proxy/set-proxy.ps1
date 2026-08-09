<#
  MAST Proxy -- operator tool to view and toggle a unit's proxy posture.

  Reuses the shared proxy-lib.ps1 (same directory), so this is the SAME
  implementation the provisioning-time proxy provider uses -- no drifting
  second copy. Deployed to C:\ProgramData\MAST\proxy by provide-proxy.ps1 and
  launched from the "MAST Proxy" Public-desktop shortcut.

  Lets an on-site operator, with no controller / WinRM / staging, put a unit on
  the Weizmann proxy (or direct) and confirm it took across all three surfaces
  (machine env, WinINet, WinHTTP).

  Setting proxy state requires elevation (machine env + netsh winhttp), so the
  tool self-elevates on launch.
#>
[CmdletBinding()]
param(
    [switch]${Interactive},
    [ValidateSet('', 'show', 'weizmann', 'direct', 'verify')]
    [string]${Action}     = '',
    [string]${HttpProxy}  = 'http://bcproxy.weizmann.ac.il:8080',
    [string]${HttpsProxy} = 'http://bcproxy.weizmann.ac.il:8080',
    [string]${NoProxy}    = '10.23.3.0/24,10.23.4.0/24'
)

${ErrorActionPreference} = 'Stop'

function Test-IsAdmin {
    ${id} = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal(${id})).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Self-elevate: machine env + netsh winhttp writes need admin. Relaunch the
# same script elevated (a new console), preserving -Interactive / -Action.
if (-not (Test-IsAdmin)) {
    Write-Host "MAST Proxy needs administrator rights to change proxy state; requesting elevation..."
    ${argList} = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', ('"{0}"' -f $PSCommandPath))
    if (${Interactive}) { ${argList} += '-Interactive' }
    if (${Action})      { ${argList} += @('-Action', ${Action}) }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ${argList}
    } catch {
        Write-Host ("Elevation was declined or failed: {0}" -f $_.Exception.Message)
    }
    return
}

${libPath} = Join-Path ${PSScriptRoot} 'proxy-lib.ps1'
if (-not (Test-Path -LiteralPath ${libPath})) { throw "proxy-lib.ps1 not found next to set-proxy.ps1 at ${libPath}" }
. ${libPath}

function Test-TcpReachable {
    # Best-effort TCP connect with a short timeout. Returns $true/$false.
    param([string]${TargetHost}, [int]${Port}, [int]${TimeoutMs} = 2500)
    ${client} = New-Object System.Net.Sockets.TcpClient
    try {
        ${iar} = ${client}.BeginConnect(${TargetHost}, ${Port}, $null, $null)
        if (-not ${iar}.AsyncWaitHandle.WaitOne(${TimeoutMs}, $false)) { return $false }
        ${client}.EndConnect(${iar})
        return $true
    } catch {
        return $false
    } finally {
        ${client}.Close()
    }
}

function Show-Posture {
    ${p} = Get-MastProxyPosture
    Write-Host ''
    Write-Host '===== MAST unit proxy posture ====='
    Write-Host '-- (A) Machine environment --'
    Write-Host ("  http_proxy  = {0}" -f $(if (${p}.Env.http_proxy)  { ${p}.Env.http_proxy }  else { '(empty)' }))
    Write-Host ("  https_proxy = {0}" -f $(if (${p}.Env.https_proxy) { ${p}.Env.https_proxy } else { '(empty)' }))
    Write-Host ("  no_proxy    = {0}" -f $(if (${p}.Env.no_proxy)    { ${p}.Env.no_proxy }    else { '(empty)' }))
    Write-Host '-- (B) WinINet (HKCU Internet Settings) --'
    Write-Host ("  ProxyEnable = {0}" -f ${p}.WinINet.Enable)
    Write-Host ("  ProxyServer = {0}" -f $(if (${p}.WinINet.Server) { ${p}.WinINet.Server } else { '(empty)' }))
    Write-Host ("  WPAD auto-detect = {0}" -f ${p}.WpadAutoDetect)
    Write-Host '-- (C) Machine WinHTTP --'
    foreach (${line} in (${p}.WinHttp -split "`r?`n")) {
        if (${line}.Trim()) { Write-Host ("  {0}" -f ${line}.Trim()) }
    }

    # Network probes so the operator sees what is actually reachable.
    Write-Host '-- Reachability probes --'
    ${bc} = Test-TcpReachable -TargetHost 'bcproxy.weizmann.ac.il' -Port 8080
    ${gh} = Test-TcpReachable -TargetHost 'github.com' -Port 443
    Write-Host ("  bcproxy.weizmann.ac.il:8080  reachable = {0}  (Weizmann campus/VPN)" -f ${bc})
    Write-Host ("  github.com:443 direct        reachable = {0}  (direct internet)" -f ${gh})
    ${onProxy} = (${p}.Env.http_proxy) -and (${p}.WinINet.Enable -eq 1)
    if (${onProxy} -and ${bc}) {
        Write-Host '  => Set to WEIZMANN proxy, and the proxy is reachable. Looks correct for on-campus.'
    } elseif (${onProxy} -and -not ${bc}) {
        Write-Host '  => Set to WEIZMANN proxy, but bcproxy is NOT reachable -- downloads will hang/fail here.'
    } elseif (-not ${onProxy} -and ${gh}) {
        Write-Host '  => Set to DIRECT, and direct internet works. Looks correct for off-campus.'
    } else {
        Write-Host '  => Set to DIRECT, but direct internet is NOT reachable -- you may need the Weizmann proxy.'
    }
    Write-Host '==================================='
    Write-Host ''
}

function Invoke-SetMode {
    param([ValidateSet('use', 'direct')][string]${Mode})
    ${label} = if (${Mode} -eq 'use') { 'WEIZMANN proxy' } else { 'DIRECT (no proxy)' }
    Write-Host ("Setting proxy state to {0} ..." -f ${label})
    Set-MastProxyState -Mode ${Mode} -HttpProxy ${HttpProxy} -HttpsProxy ${HttpsProxy} -NoProxy ${NoProxy}
    Write-Host 'Done.'
    Show-Posture
}

function Invoke-Action {
    param([string]${Name})
    switch (${Name}) {
        'show'     { Show-Posture }
        'verify'   { Show-Posture }
        'weizmann' { Invoke-SetMode -Mode 'use' }
        'direct'   { Invoke-SetMode -Mode 'direct' }
        default    { Show-Posture }
    }
}

if (${Action}) {
    Invoke-Action -Name ${Action}
    if (-not ${Interactive}) { return }
}

if (-not ${Interactive}) {
    # No action and not interactive: default to a read-only Show.
    Show-Posture
    return
}

# Interactive menu.
while ($true) {
    Write-Host 'MAST Proxy'
    Write-Host '  1) Show current posture'
    Write-Host '  2) Set WEIZMANN proxy'
    Write-Host '  3) Set DIRECT (no proxy)'
    Write-Host '  4) Re-verify (show again)'
    Write-Host '  5) Quit'
    ${choice} = Read-Host 'Choose 1-5'
    switch (${choice}.Trim()) {
        '1' { Show-Posture }
        '2' { Invoke-SetMode -Mode 'use' }
        '3' { Invoke-SetMode -Mode 'direct' }
        '4' { Show-Posture }
        '5' { break }
        default { Write-Host 'Please enter 1-5.' }
    }
}
