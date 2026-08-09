# Proxy-posture assertion helper for the provisioning driver.
#
# Proxy state on a unit is owned solely by the `proxy` provider. This file is
# the READ-ONLY decision half of the driver's end-of-run guard: given the proxy
# surfaces read off a unit, classify which are still pointing at a proxy.
#
# Why this exists: on mast03 (2026-07-08) a `-ProxyMode direct` run ended with
# bcproxy still set, so `git fetch` in the mast module died with
# "Could not resolve proxy: bcproxy". The re-introduction was intermittent (a
# later run was clean) and is not reproducible from the current code -- no
# module outside the proxy provider writes proxy state -- so rather than patch
# a phantom, the driver runs this check AFTER the last module and turns a
# silent re-introduction into a loud, surface-naming failure.
#
# Critical vs. advisory: git (and env-honoring tools) read the machine
# http_proxy/https_proxy ENV vars -- those are what broke the run, so a dirty
# env surface on a direct run is a hard failure. WinINet (IE/UI apps) and
# WinHTTP (Windows Update / BITS) are real proxy surfaces but do not break git;
# a dirty one is reported as advisory, not fatal.

function Get-ProxyDirtySurfaces {
    # $Posture is the object read off the unit with fields:
    #   http_proxy, https_proxy      (machine-scope env var values, or $null)
    #   wininet_enable, wininet_server (HKCU Internet Settings ProxyEnable/Server)
    #   winhttp                       ('netsh winhttp show proxy' text)
    # Returns @{ Critical = @(...); Advisory = @(...) } of "surface=value" strings.
    param([Parameter(Mandatory)]$Posture)

    $critical = @()
    $advisory = @()

    if ($Posture.http_proxy)  { $critical += "http_proxy=$($Posture.http_proxy)" }
    if ($Posture.https_proxy) { $critical += "https_proxy=$($Posture.https_proxy)" }

    if ((([int]$Posture.wininet_enable) -eq 1) -and $Posture.wininet_server) {
        $advisory += "wininet=$($Posture.wininet_server)"
    }
    if ($Posture.winhttp -and ($Posture.winhttp -match 'Proxy Server\(s\)\s*:\s*\S')) {
        $advisory += 'winhttp=set'
    }

    return @{ Critical = @($critical); Advisory = @($advisory) }
}
