param(
    [string]${HttpProxy}  = "http://bcproxy.weizmann.ac.il:8080",
    [string]${HttpsProxy} = "http://bcproxy.weizmann.ac.il:8080",
    [string]${NoProxy}    = "10.23.3.0/24,10.23.4.0/24",
    # Override knobs (rare):
    #   -ForceMode probe   : probe the proxy and use it only if reachable (DEFAULT)
    #   -ForceMode use     : always set the env vars regardless of reachability
    #   -ForceMode direct  : always clear the env vars (force direct internet)
    [ValidateSet('probe','use','direct')]
    [string]${ForceMode}  = 'probe'
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
Soft proxy provider.

Originally this hardcoded the Weizmann web proxy as machine-scope env vars
(http_proxy, https_proxy, no_proxy). That worked when the unit was on the
Weizmann campus network where bcproxy.weizmann.ac.il is reachable, but
broke every subsequent provisioning step on a unit that does NOT have that
proxy in its routing table -- for example the VirtualBox dev VM on a home
network (2026-05-25). pip install, git clone, curl, npm, anything that
honors http_proxy gets routed through an unreachable host and fails.

New behavior (ForceMode = 'probe', the default):
  1. TCP-probe the proxy host:port.
  2. If reachable: set the env vars (preserves the original behavior on
     Weizmann campus).
  3. If unreachable: clear the env vars (force direct internet so all
     downstream HTTP tools just work).

Override modes:
  - 'use':    always set the vars regardless of reachability (legacy
              behavior; useful if the proxy is up but the TCP probe
              would be inconclusive, e.g. ICMP-only firewall).
  - 'direct': always clear the vars (useful for known-direct units).

The smoke marker records which mode actually applied so downstream
verification can see at a glance whether this unit is proxy'd or direct.
#>

function Test-ProxyReachable {
    param([string]$ProxyUrl)
    # Parse host:port out of http://host:port[/...] or host:port
    $u = $ProxyUrl
    if ($u -match '^https?://') {
        try {
            $uri = [System.Uri]$u
            $h = $uri.Host; $p = $uri.Port
            if ($p -le 0) { $p = 80 }
        } catch { return $false }
    } else {
        $parts = $u -split ':'
        if ($parts.Count -ne 2) { return $false }
        $h = $parts[0]; $p = [int]$parts[1]
    }
    if (-not $h) { return $false }
    try {
        $r = Test-NetConnection -ComputerName $h -Port $p `
            -WarningAction SilentlyContinue -InformationLevel Quiet -ErrorAction Stop
        return [bool]$r
    } catch {
        return $false
    }
}

try {
    # Decide effective mode (probe -> use|direct based on reachability)
    $effective = $ForceMode
    if ($ForceMode -eq 'probe') {
        # Use HttpsProxy as the probe target -- it's the one used by tools that
        # actually need to download packages. We just probe the TCP socket;
        # whether the proxy actually proxies requests is a separate question
        # (and one that 'direct' would not solve for us either).
        Write-ProxyLog ("Probing {0} for reachability..." -f ${HttpsProxy})
        if (Test-ProxyReachable -ProxyUrl ${HttpsProxy}) {
            $effective = 'use'
            Write-ProxyLog "  Proxy is reachable; setting env vars."
        } else {
            $effective = 'direct'
            Write-ProxyLog "  Proxy is NOT reachable; clearing env vars so HTTP tools go direct."
        }
    } else {
        Write-ProxyLog ("ForceMode={0}; skipping reachability probe." -f $ForceMode)
    }

    ${pairs} = @(
        @{ Name = 'http_proxy';  Value = ${HttpProxy}  },
        @{ Name = 'https_proxy'; Value = ${HttpsProxy} },
        @{ Name = 'no_proxy';    Value = ${NoProxy}    }
    )

    if ($effective -eq 'use') {
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
        # 'direct' (or auto-downgraded from 'probe')
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

    # Verification readback. In 'use' we expect the configured values; in
    # 'direct' we expect them all empty/null.
    foreach (${p} in ${pairs}) {
        ${current} = [Environment]::GetEnvironmentVariable(${p}.Name, 'Machine')
        if ($effective -eq 'use') {
            if (${current} -ne ${p}.Value) {
                throw ("Machine env {0} did not stick: got '{1}', expected '{2}'" -f ${p}.Name, ${current}, ${p}.Value)
            }
        } else {
            if (-not [string]::IsNullOrEmpty(${current})) {
                throw ("Machine env {0} should be cleared in '{1}' mode but is '{2}'" -f ${p}.Name, $effective, ${current})
            }
        }
    }

    ${smokeDir} = Get-MastSmokeDir
    New-Item -ItemType Directory -Path ${smokeDir} -Force | Out-Null
    Set-Content -LiteralPath (Join-Path ${smokeDir} 'proxy-smoke.txt') -Encoding UTF8 `
        -Value ("proxy_ok mode={0}" -f $effective)

    Write-ProxyLog ("Proxy provisioning completed (mode={0})." -f $effective)
    exit 0
}
catch {
    ${errorMsg} = ("Proxy provisioning failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
