#requires -Version 5.1
[CmdletBinding()]
param(
    [string]${Role} = 'unit'
)

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off
${verifyLog} = Get-MastVerifyLog -Module 'config-bootstrap'

function W { param([string]${Line}) Add-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), ${Line}) }
Set-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] verify-config-bootstrap.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

${fail} = @()

# 1) C:\WIS\<role>.toml exists and carries the required bootstrap keys. Parsed with a
# light line check (no tomllib: python is order 600, not yet installed at order 150).
${targetPath} = 'C:\WIS\{0}.toml' -f ${Role}
if (Test-Path -LiteralPath ${targetPath}) {
    W ("bootstrap file present: {0}" -f ${targetPath})
    ${content} = Get-Content -LiteralPath ${targetPath} -Raw
    foreach (${key} in 'site', 'project', 'controller_host', 'database', 'domain') {
        if (${content} -notmatch ("(?m)^\s*{0}\s*=" -f ${key})) { ${fail} += ("missing key '{0}' in {1}" -f ${key}, ${targetPath}) }
    }
    if (${content} -notmatch '(?m)^\s*\[location\]') { ${fail} += "missing [location] section" }
    foreach (${key} in 'latitude', 'longitude', 'elevation') {
        if (${content} -notmatch ("(?m)^\s*{0}\s*=" -f ${key})) { ${fail} += ("missing location key '{0}'" -f ${key}) }
    }
} else {
    ${fail} += ("bootstrap file missing: {0}" -f ${targetPath})
}

# 2) MAST_PROJECT machine env var is set to the role.
${mp} = [Environment]::GetEnvironmentVariable('MAST_PROJECT', 'Machine')
W ("MAST_PROJECT (Machine) = '{0}' (expect '{1}')" -f ${mp}, ${Role})
if (${mp} -ne ${Role}) { ${fail} += ("MAST_PROJECT machine env is '{0}', expected '{1}'" -f ${mp}, ${Role}) }

if (${fail}.Count -eq 0) {
    W 'PASS bootstrap config + MAST_PROJECT in place'
    Write-MastSmokeOk -Module 'config-bootstrap' | Out-Null
    exit 0
}
W ('FAIL ' + (${fail} -join '; '))
exit 1
