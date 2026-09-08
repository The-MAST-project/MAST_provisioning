#requires -Version 5.1
[CmdletBinding()]
param(
    [string]${ExpectedHttpProxy} = 'http://bcproxy.weizmann.ac.il:8080'
)

${ErrorActionPreference} = 'Stop'

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts predate it and probe optional properties

# The bypass list is asserted below against the same default the provider
# writes, so the two cannot drift. Should the provider ever be given a per-run
# -NoProxy, it has to be injected here from module.json's verify command the way
# desktop-shortcuts injects -FastApiUrl -- an expectation read from the lib
# would then be checking the wrong thing.
${proxyLibDot} = Join-Path ${PSScriptRoot} 'proxy-lib.ps1'
if (-not (Test-Path -LiteralPath ${proxyLibDot})) { throw "proxy-lib.ps1 not found next to verify-proxy.ps1 at ${proxyLibDot}" }
. ${proxyLibDot}

${verifyLog} = Get-MastVerifyLog -Module 'proxy'
${smokeFile} = Get-MastSmokeMarker -Module 'proxy'

function Write-VLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${verifyLog} -Encoding UTF8 `
    -Value ("[{0}] verify-proxy.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# Always emit diagnostics first, so if we fail, the log has everything we need.
${envHttp}  = [Environment]::GetEnvironmentVariable('http_proxy',  'Machine')
${envHttps} = [Environment]::GetEnvironmentVariable('https_proxy', 'Machine')
${envNo}    = [Environment]::GetEnvironmentVariable('no_proxy',    'Machine')

${ie} = @{ Enable = 0; Server = ''; Override = '' }
${ieKey} = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
if (Test-Path ${ieKey}) {
    try {
        ${p} = Get-ItemProperty -Path ${ieKey} -ErrorAction Stop
        if ($null -ne ${p}.ProxyEnable)   { ${ie}.Enable   = [int]${p}.ProxyEnable }
        if ($null -ne ${p}.ProxyServer)   { ${ie}.Server   = [string]${p}.ProxyServer }
        if ($null -ne ${p}.ProxyOverride) { ${ie}.Override = [string]${p}.ProxyOverride }
    } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
}

Write-VLog ("env(Machine): http_proxy='{0}' https_proxy='{1}' no_proxy='{2}'" -f ${envHttp}, ${envHttps}, ${envNo})
Write-VLog ("WinINet:      ProxyEnable={0} ProxyServer='{1}' ProxyOverride='{2}'" -f ${ie}.Enable, ${ie}.Server, ${ie}.Override)

# Read the smoke marker the provider left behind.
${smokeBody} = ''
if (Test-Path -LiteralPath ${smokeFile}) {
    try {
        ${smokeBody} = (Get-Content -LiteralPath ${smokeFile} -Raw -ErrorAction Stop).TrimEnd("`r","`n"," ","`t")
    } catch {
        Write-VLog ("FAIL: cannot read smoke file {0}: {1}" -f ${smokeFile}, $_.Exception.Message)
        exit 1
    }
} else {
    Write-VLog ("FAIL: smoke marker missing at {0}" -f ${smokeFile})
    exit 1
}
Write-VLog ("smoke: {0}" -f ${smokeBody})

# Decide which mode the provider chose, then verify each surface matches.
${mode} = $null
if (${smokeBody} -match 'mode=use')         { ${mode} = 'use' }
elseif (${smokeBody} -match 'mode=direct')  { ${mode} = 'direct' }
else {
    Write-VLog ("FAIL: smoke body did not contain mode=use|direct: '{0}'" -f ${smokeBody})
    exit 1
}

${issues} = New-Object 'System.Collections.Generic.List[string]'

${expectedNoProxy} = Get-MastDefaultNoProxy
${expectedBypass}  = Convert-NoProxyToWildcardBypass ${expectedNoProxy}

if (${mode} -eq 'use') {
    if (${envHttp}  -ne ${ExpectedHttpProxy}) { [void]${issues}.Add("env http_proxy='${envHttp}' != expected '${ExpectedHttpProxy}'") }
    if (${envHttps} -ne ${ExpectedHttpProxy}) { [void]${issues}.Add("env https_proxy='${envHttps}' != expected '${ExpectedHttpProxy}'") }
    if (${ie}.Enable -ne 1)                   { [void]${issues}.Add("WinINet ProxyEnable=$(${ie}.Enable), expected 1") }
    if ([string]::IsNullOrEmpty(${ie}.Server)){ [void]${issues}.Add("WinINet ProxyServer is empty") }
    # The bypass list is the surface that decides whether a unit can reach its
    # own subnet without a round trip through bcproxy, and nothing asserted it
    # until now -- a wrong list stayed green on the whole fleet.
    if (${envNo} -ne ${expectedNoProxy})      { [void]${issues}.Add("env no_proxy='${envNo}' != expected '${expectedNoProxy}'") }
    if (${ie}.Override -ne ${expectedBypass}) { [void]${issues}.Add("WinINet ProxyOverride='$(${ie}.Override)' != expected '${expectedBypass}'") }
} else {
    # direct
    if (-not [string]::IsNullOrEmpty(${envHttp}))  { [void]${issues}.Add("env http_proxy should be empty in direct mode but is '${envHttp}'") }
    if (-not [string]::IsNullOrEmpty(${envHttps})) { [void]${issues}.Add("env https_proxy should be empty in direct mode but is '${envHttps}'") }
    if (-not [string]::IsNullOrEmpty(${envNo}))    { [void]${issues}.Add("env no_proxy should be empty in direct mode but is '${envNo}'") }
    if (${ie}.Enable -ne 0)                        { [void]${issues}.Add("WinINet ProxyEnable=$(${ie}.Enable), expected 0 in direct mode") }
    if (-not [string]::IsNullOrEmpty(${ie}.Override)) { [void]${issues}.Add("WinINet ProxyOverride should be cleared in direct mode but is '$(${ie}.Override)'") }
}

if (${issues}.Count -gt 0) {
    foreach (${i} in ${issues}) { Write-VLog ("FAIL: {0}" -f ${i}) }
    exit 1
}

Write-VLog ("PASS: proxy state consistent with mode={0}" -f ${mode})
exit 0
