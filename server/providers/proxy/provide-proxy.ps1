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

# All proxy-surface logic lives in the shared proxy-lib.ps1 (same directory), so
# this provider and the operator set-proxy.ps1 desktop tool share ONE
# implementation. Route the lib's output into this provider's log.
${proxyLibDot} = Join-Path ${PSScriptRoot} 'proxy-lib.ps1'
if (-not (Test-Path ${proxyLibDot})) { throw "proxy-lib.ps1 not found next to provide-proxy.ps1 at ${proxyLibDot}" }
. ${proxyLibDot}
Set-ProxyLibLogger { param(${m}) Write-ProxyLog ${m} }

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

The provider manages THREE proxy surfaces in lockstep (see proxy-lib.ps1):
  A. Machine-scope env vars: http_proxy, https_proxy, no_proxy
  B. HKCU IE / WinINet proxy (ProxyEnable/ProxyServer/ProxyOverride + flags blob)
  C. Machine WinHTTP (via `netsh winhttp set/reset proxy`)
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

# Deploy the operator "MAST Proxy" desktop tool + the shared lib to a stable
# on-unit path, mirroring instrument-profiles -> calibrate-instruments.ps1. The
# desktop-shortcuts provider makes the "MAST Proxy" shortcut target this copy.
function Publish-ProxyTool {
    ${toolRoot} = 'C:\ProgramData\MAST\proxy'
    New-Item -ItemType Directory -Path ${toolRoot} -Force | Out-Null
    foreach (${name} in @('set-proxy.ps1', 'proxy-lib.ps1')) {
        ${src} = Join-Path ${PSScriptRoot} ${name}
        if (Test-Path -LiteralPath ${src}) {
            Copy-Item -LiteralPath ${src} -Destination (Join-Path ${toolRoot} ${name}) -Force
            Write-ProxyLog ("Deployed {0} -> {1}" -f ${name}, ${toolRoot})
        } else {
            Write-ProxyLog ("[WARN] {0} not found at {1}; operator proxy tool not deployed." -f ${name}, ${src})
        }
    }
}

try {
    Show-ProxyBanner -Mode $ForceMode

    # Flip all three surfaces to match the mode (shared implementation).
    Set-MastProxyState -Mode ${ForceMode} -HttpProxy ${HttpProxy} -HttpsProxy ${HttpsProxy} -NoProxy ${NoProxy}

    # ----- Verification readback -----
    ${hostPort} = Get-ProxyHostPort -ProxyUrl ${HttpsProxy}
    ${pairs} = @(
        @{ Name = 'http_proxy';  Value = ${HttpProxy}  },
        @{ Name = 'https_proxy'; Value = ${HttpsProxy} },
        @{ Name = 'no_proxy';    Value = ${NoProxy}    }
    )
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
    ${autoDetect} = Get-WinINetAutoDetect
    Write-ProxyLog ("WinINet readback: ProxyEnable={0} ProxyServer='{1}' ProxyOverride='{2}' wpadAutoDetect={3}" -f ${ie}.Enable, ${ie}.Server, ${ie}.Override, ${autoDetect})
    if ($ForceMode -eq 'use') {
        if (${ie}.Enable -ne 1) { throw "WinINet ProxyEnable should be 1 in 'use' mode but is $($ie.Enable)" }
        if (${ie}.Server -ne ${hostPort}) { throw "WinINet ProxyServer should be '${hostPort}' but is '$($ie.Server)'" }
    } else {
        if (${ie}.Enable -ne 0) { throw "WinINet ProxyEnable should be 0 in 'direct' mode but is $($ie.Enable)" }
    }
    if (${autoDetect}) {
        throw "WinINet WPAD auto-detect (DefaultConnectionSettings flag 0x08) is still set after configuration; cryptnet revocation retrieval will fail on multi-homed hosts."
    }

    # Smoke marker (ASCII, no BOM). Includes mode so downstream verify and
    # other providers (notably astrometry-dependencies' setup.rc selector)
    # can read it without re-deriving the mode.
    ${smokeDir} = Get-MastSmokeDir
    New-Item -ItemType Directory -Path ${smokeDir} -Force | Out-Null
    Set-Content -LiteralPath (Join-Path ${smokeDir} 'proxy-smoke.txt') -Encoding ASCII `
        -Value ("proxy_ok mode={0} ie_enable={1} ie_server='{2}' wpad_autodetect={3}" -f $ForceMode, ${ie}.Enable, ${ie}.Server, ${autoDetect})

    # Ship the operator toggle tool + shared lib to the unit.
    Publish-ProxyTool

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
