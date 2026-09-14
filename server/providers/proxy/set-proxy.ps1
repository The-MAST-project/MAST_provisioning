<#
  Weizmann Proxy -- operator tool to view and toggle a unit's proxy posture.

  Named for what it selects: the Weizmann campus proxy, bcproxy. It is not a
  MAST service and there is no MAST proxy; the earlier "MAST Proxy" label
  implied both.

  Reuses the shared proxy-lib.ps1 (same directory), so this is the SAME
  implementation the provisioning-time proxy provider uses -- no drifting
  second copy. Deployed to C:\ProgramData\MAST\proxy by provide-proxy.ps1 and
  launched from the "Weizmann Proxy" Public-desktop shortcut.

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
    # Filled from proxy-lib.ps1 below, after the dot-source -- one bypass list
    # for the provider and this tool both.
    [string]${NoProxy}
)

${ErrorActionPreference} = 'Stop'

function Test-IsAdmin {
    ${id} = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal(${id})).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Self-elevate: machine env + netsh winhttp writes need admin. Relaunch the
# same script elevated (a new console), preserving -Interactive / -Action.
if (-not (Test-IsAdmin)) {
    Write-Host "Weizmann Proxy needs administrator rights to change proxy state; requesting elevation..."
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
if (-not $PSBoundParameters.ContainsKey('NoProxy')) { ${NoProxy} = Get-MastDefaultNoProxy }

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
    # No AutoConfigURL line on purpose -- see Get-WinINetProxyState in
    # proxy-lib.ps1 for why a PAC path is not part of the posture here.
    Write-Host ("  WPAD auto-detect = {0}" -f ${p}.WpadAutoDetect)
    Write-Host '-- (C) Machine WinHTTP --'
    foreach (${line} in (${p}.WinHttp -split "`r?`n")) {
        if (${line}.Trim()) { Write-Host ("  {0}" -f ${line}.Trim()) }
    }

    # Network probes so the operator sees what is actually reachable.
    Write-Host '-- Reachability probes --'
    ${bc} = Test-TcpReachable -TargetHost 'bcproxy.weizmann.ac.il' -Port 8080
    ${gh} = Test-TcpReachable -TargetHost 'github.com' -Port 443
    Write-Host ("  bcproxy.weizmann.ac.il:8080  reachable = {0}  (campus, VPN, or Neot Smadar)" -f ${bc})
    Write-Host ("  github.com:443 direct        reachable = {0}  (direct internet)" -f ${gh})

    # Where we are is the PAIR of probes, not either one alone. bcproxy is
    # reachable from Neot Smadar as well as campus (measured from mast01,
    # 2026-09-14), and direct egress works ON campus -- so "bcproxy up" does
    # not mean campus, and "direct works" does not mean off-campus. Only the
    # combination separates the four places, and only one of them makes a
    # posture actually wrong rather than merely unconventional.
    Write-Host ("  => location: {0}" -f $(
        if (${bc} -and ${gh})           { 'inside the institute (campus or VPN) -- both routes work' }
        elseif (${bc} -and -not ${gh})  { 'Neot Smadar, or another proxy-only segment' }
        elseif (-not ${bc} -and ${gh})  { 'off campus -- no route to bcproxy' }
        else                            { 'isolated segment -- no egress either way' }))

    ${onProxy} = (${p}.Env.http_proxy) -and (${p}.WinINet.Enable -eq 1)
    if (${onProxy} -and ${bc}) {
        Write-Host '  => Set to WEIZMANN proxy, and the proxy is reachable. Correct here.'
    } elseif (${onProxy} -and -not ${bc}) {
        Write-Host '  => WRONG: set to WEIZMANN proxy, but bcproxy is NOT reachable -- downloads will hang.'
    } elseif (-not ${onProxy} -and ${bc} -and -not ${gh}) {
        Write-Host '  => WRONG: set to DIRECT on a proxy-only segment -- there is no way out without the proxy.'
    } elseif (-not ${onProxy} -and ${gh}) {
        Write-Host '  => Set to DIRECT, and direct internet works. Correct here.'
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
#
# The posture is shown before the menu rather than behind a menu item: the
# question an operator opens this with is "what is it set to right now", and
# making that the first thing on screen answers it without a keystroke.
# Invoke-SetMode re-shows it after every change, so the display always reflects
# what the unit is actually doing.
Show-Posture
# A flag, not `break`. In PowerShell a bare `break` inside a switch exits the
# SWITCH, not an enclosing loop, so the quit branch redrew the menu forever and
# the only way out of this tool was closing its window.
${running} = $true
while (${running}) {
    Write-Host 'Weizmann Proxy'
    Write-Host '  1) Use the WEIZMANN proxy (bcproxy)'
    Write-Host '  2) Go DIRECT (no proxy)'
    Write-Host '  3) Show the current setting again'
    Write-Host '  4) Quit'
    ${choice} = Read-Host 'Choose 1-4'
    switch (${choice}.Trim()) {
        '1' { Invoke-SetMode -Mode 'use' }
        '2' { Invoke-SetMode -Mode 'direct' }
        '3' { Show-Posture }
        '4' { ${running} = $false }
        default { Write-Host 'Please enter 1-4.' }
    }
}
