param(
    [string]${HttpProxy}  = "http://bcproxy.weizmann.ac.il:8080",
    [string]${HttpsProxy} = "http://bcproxy.weizmann.ac.il:8080",
    [string]${NoProxy}    = "10.23.3.0/24,10.23.4.0/24",
    # Run mode -- chosen explicitly by the operator at provisioning time,
    # NOT probed at runtime. Pick based on whether THIS RUN can reach
    # bcproxy.weizmann.ac.il:8080 (i.e. unit is on the Weizmann campus
    # network or connected via the Weizmann VPN). 'dev' vs 'prod' is
    # orthogonal to this choice -- a dev run inside the network uses
    # 'use'; a prod-style run from a satellite site without VPN uses
    # 'direct'. See build-mast.ps1 -ProxyMode for how this is plumbed
    # end-to-end and DECISIONS.md 2026-05-26.
    [ValidateSet('use','direct')]
    [string]${ForceMode}  = 'use'
)

${ErrorActionPreference} = "Stop"

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}

${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "proxy-install.log"

function Write-ProxyLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-proxy.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

<#
Soft proxy provider -- now hard, by explicit operator choice.

Earlier iterations of this provider tried to auto-detect the network and
pick a proxy mode by probing bcproxy.weizmann.ac.il. That seemed clever but
turned out to be a fragile foundation:
  - Cygwin setup-x86_64.exe ignores the env vars we set and reads its own
    proxy state from WinINet plus WPAD autodiscovery, so "probe says no
    proxy" did not stop setup.exe from picking one.
  - "Which network is the unit on right now" is something the operator
    actually knows at provisioning time -- treating it as something the
    script must rediscover every run is fragile and hides intent.

Replaced 2026-05-26 with an explicit mode that flows from
`vm/run-prov-test.py --proxy-mode {weizmann,direct}` through
`build/build-mast.ps1 -ProxyMode {weizmann,direct}` into this provider's
command line as `-ForceMode {use,direct}`. Defaults are configured for
the on-campus case (the common case in this project). Runs against a
unit that cannot reach bcproxy MUST pass `--proxy-mode direct` -- this
applies whether the run is dev or prod; the deciding factor is the
unit's network reachability, not the run's purpose.

The provider manages THREE proxy surfaces in lockstep:
  A. Machine-scope env vars: http_proxy, https_proxy, no_proxy
     (curl, wget, pip, npm, git, requests, urllib3, ...)
  B. HKCU IE / WinINet proxy:
       HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings
         ProxyEnable, ProxyServer, ProxyOverride
     (cygwin setup-x86_64.exe, Edge/IE, .NET HttpClient default, MSI
      bootstrap downloads.)
  C. Machine WinHTTP (via `netsh winhttp set/reset proxy`)
     (Windows Update agent, BITS, COM-side services.)
#>

function Show-ProxyBanner {
    param([string]$Mode)
    # Banners are designed to be unmistakable in scrolling provisioning
    # output -- so an operator skimming a 90-min run log can immediately
    # see "ah, this was a direct run, that's why X happened."
    $tag = if ($Mode -eq 'use') { '*** WEIZMANN-PROXY MODE ***' } else { '*** NO-WEIZMANN-PROXY (DIRECT) MODE ***' }
    Write-ProxyLog "==================================================================="
    Write-ProxyLog $tag
    Write-ProxyLog "==================================================================="
}

function Get-ProxyHostPort {
    # Parse 'host:port' out of 'http://host:port[/...]' or 'host:port'.
    # Returns "host:port" or $null on parse failure.
    param([string]$ProxyUrl)
    if ([string]::IsNullOrEmpty($ProxyUrl)) { return $null }
    if ($ProxyUrl -match '^https?://') {
        try {
            $uri = [System.Uri]$ProxyUrl
            $h = $uri.Host
            $p = $uri.Port
            if ($p -le 0) { $p = 80 }
            if (-not $h) { return $null }
            return ("{0}:{1}" -f $h, $p)
        } catch { return $null }
    }
    if ($ProxyUrl -match '^[^:/]+:\d+$') { return $ProxyUrl }
    return $null
}

function Set-WinINetProxy {
    # HKCU IE / WinINet proxy. cygwin setup-x86_64.exe and many other
    # Windows tools read these. Provisioning runs as 'mast' user; setup.exe
    # child runs as 'mast' too, so HKCU of the same user is what matters.
    param(
        [Parameter(Mandatory)][bool]$Enable,
        [string]$HostPort,
        [string]$NoProxyList
    )
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    if ($Enable) {
        Set-ItemProperty -Path $k -Name 'ProxyEnable' -Type DWord  -Value 1
        Set-ItemProperty -Path $k -Name 'ProxyServer' -Type String -Value $HostPort
        if ($NoProxyList) {
            $bypass = ($NoProxyList -split ',') -join ';'
            Set-ItemProperty -Path $k -Name 'ProxyOverride' -Type String -Value $bypass
        } else {
            Remove-ItemProperty -Path $k -Name 'ProxyOverride' -ErrorAction SilentlyContinue
        }
    } else {
        Set-ItemProperty -Path $k -Name 'ProxyEnable' -Type DWord -Value 0
        Set-ItemProperty -Path $k -Name 'ProxyServer' -Type String -Value ''
        Remove-ItemProperty -Path $k -Name 'ProxyOverride' -ErrorAction SilentlyContinue
    }
}

function Get-WinINetProxyState {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $h = @{ Enable = 0; Server = ''; Override = '' }
    if (-not (Test-Path $k)) { return $h }
    try {
        $p = Get-ItemProperty -Path $k -ErrorAction Stop
        if ($null -ne $p.ProxyEnable)   { $h.Enable   = [int]$p.ProxyEnable }
        if ($null -ne $p.ProxyServer)   { $h.Server   = [string]$p.ProxyServer }
        if ($null -ne $p.ProxyOverride) { $h.Override = [string]$p.ProxyOverride }
    } catch {}
    return $h
}

function Set-WinHttpProxy {
    param(
        [Parameter(Mandatory)][bool]$Enable,
        [string]$HostPort,
        [string]$NoProxyList
    )
    if ($Enable) {
        $bypass = if ($NoProxyList) { ($NoProxyList -split ',') -join ';' } else { '<local>' }
        $cmd = "netsh winhttp set proxy `"$HostPort`" `"$bypass`""
    } else {
        $cmd = "netsh winhttp reset proxy"
    }
    Write-ProxyLog ("  WinHTTP: {0}" -f $cmd)
    $out = & cmd /c $cmd 2>&1
    foreach ($line in $out) { Write-ProxyLog ("    {0}" -f $line) }
}

try {
    Show-ProxyBanner -Mode $ForceMode

    ${pairs} = @(
        @{ Name = 'http_proxy';  Value = ${HttpProxy}  },
        @{ Name = 'https_proxy'; Value = ${HttpsProxy} },
        @{ Name = 'no_proxy';    Value = ${NoProxy}    }
    )

    # ----- (A) Machine env vars -----
    if ($ForceMode -eq 'use') {
        foreach (${p} in ${pairs}) {
            ${prev}  = [Environment]::GetEnvironmentVariable(${p}.Name, 'Machine')
            if (${prev} -eq ${p}.Value) {
                Write-ProxyLog ("{0} already set to expected value; skipping" -f ${p}.Name)
                continue
            }
            Write-ProxyLog ("Setting machine env: {0} = {1} (previous: {2})" -f ${p}.Name, ${p}.Value, ${prev})
            [Environment]::SetEnvironmentVariable(${p}.Name, ${p}.Value, 'Machine')
        }
    } else {
        foreach (${p} in ${pairs}) {
            ${prev} = [Environment]::GetEnvironmentVariable(${p}.Name, 'Machine')
            if ([string]::IsNullOrEmpty(${prev})) {
                Write-ProxyLog ("{0} already empty; skipping" -f ${p}.Name)
                continue
            }
            Write-ProxyLog ("Clearing machine env: {0} (was: {1})" -f ${p}.Name, ${prev})
            [Environment]::SetEnvironmentVariable(${p}.Name, $null, 'Machine')
        }
    }

    # ----- (B) WinINet / IE proxy -----
    ${hostPort} = Get-ProxyHostPort -ProxyUrl ${HttpsProxy}
    if ($ForceMode -eq 'use') {
        if (-not ${hostPort}) {
            throw ("Cannot parse host:port out of HttpsProxy='{0}'." -f ${HttpsProxy})
        }
        Write-ProxyLog ("Setting WinINet proxy: ProxyEnable=1 ProxyServer={0} ProxyOverride={1}" -f ${hostPort}, ${NoProxy})
        Set-WinINetProxy -Enable $true -HostPort ${hostPort} -NoProxyList ${NoProxy}
    } else {
        Write-ProxyLog "Clearing WinINet proxy: ProxyEnable=0"
        Set-WinINetProxy -Enable $false
    }

    # ----- (C) Machine WinHTTP -----
    if ($ForceMode -eq 'use') {
        Set-WinHttpProxy -Enable $true -HostPort ${hostPort} -NoProxyList ${NoProxy}
    } else {
        Set-WinHttpProxy -Enable $false
    }

    # ----- Verification readback -----
    foreach (${p} in ${pairs}) {
        ${current} = [Environment]::GetEnvironmentVariable(${p}.Name, 'Machine')
        if ($ForceMode -eq 'use') {
            if (${current} -ne ${p}.Value) {
                throw ("Machine env {0} did not stick: got '{1}', expected '{2}'" -f ${p}.Name, ${current}, ${p}.Value)
            }
        } else {
            if (-not [string]::IsNullOrEmpty(${current})) {
                throw ("Machine env {0} should be cleared in 'direct' mode but is '{1}'" -f ${p}.Name, ${current})
            }
        }
    }
    ${ie} = Get-WinINetProxyState
    Write-ProxyLog ("WinINet readback: ProxyEnable={0} ProxyServer='{1}' ProxyOverride='{2}'" -f ${ie}.Enable, ${ie}.Server, ${ie}.Override)
    if ($ForceMode -eq 'use') {
        if (${ie}.Enable -ne 1) { throw "WinINet ProxyEnable should be 1 in 'use' mode but is $($ie.Enable)" }
        if (${ie}.Server -ne ${hostPort}) { throw "WinINet ProxyServer should be '${hostPort}' but is '$($ie.Server)'" }
    } else {
        if (${ie}.Enable -ne 0) { throw "WinINet ProxyEnable should be 0 in 'direct' mode but is $($ie.Enable)" }
    }

    # Smoke marker (ASCII, no BOM). Includes mode so downstream verify and
    # other providers (notably astrometry-dependencies' setup.rc selector)
    # can read it without re-deriving the mode.
    ${smokeDir} = Get-MastSmokeDir
    New-Item -ItemType Directory -Path ${smokeDir} -Force | Out-Null
    Set-Content -LiteralPath (Join-Path ${smokeDir} 'proxy-smoke.txt') -Encoding ASCII `
        -Value ("proxy_ok mode={0} ie_enable={1} ie_server='{2}'" -f $ForceMode, ${ie}.Enable, ${ie}.Server)

    Show-ProxyBanner -Mode $ForceMode
    Write-ProxyLog ("Proxy provisioning completed (mode={0})." -f $ForceMode)
    exit 0
}
catch {
    ${errorMsg} = ("Proxy provisioning failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
