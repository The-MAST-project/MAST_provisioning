param(
    # Site whose profile (sites/<Site>.toml) becomes this machine's bootstrap config.
    # Injected by build-mast.ps1 -Site (mirrors the proxy/astrometry command tweaks).
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]${Site},
    [string]${AssetsRoot} = '.',
    # Machine role -> MAST_PROJECT and the C:\WIS\<role>.toml file name. Units only today.
    [string]${Role} = 'unit'
)

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} 'config-bootstrap.log'

function Write-CfgLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-config-bootstrap.ps1 started (Site={1}, Role={2})." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ${Site}, ${Role})

# Locate the staged site profile (build flattens 'sites/<site>.toml' next to this script).
${siteFile} = Join-Path ${PSScriptRoot} ('sites\{0}.toml' -f ${Site})
if (-not (Test-Path -LiteralPath ${siteFile})) {
    ${siteFile} = Join-Path ${AssetsRoot} ('sites\{0}.toml' -f ${Site})
}
if (-not (Test-Path -LiteralPath ${siteFile})) {
    throw ("site profile not staged: sites\{0}.toml (build with -Site {0})" -f ${Site})
}
Write-CfgLog ("Site profile: {0}" -f ${siteFile})

# Deploy verbatim to C:\WIS\<role>.toml. The file is copied as-is (single source of
# truth in the repo); MAST_common reads it utf-8-sig so a BOM, if any, is tolerated.
${targetPath} = 'C:\WIS\{0}.toml' -f ${Role}
${wisDir} = Split-Path -Parent ${targetPath}
New-Item -ItemType Directory -Path ${wisDir} -Force | Out-Null
Copy-Item -LiteralPath ${siteFile} -Destination ${targetPath} -Force
Write-CfgLog ("Wrote {0}" -f ${targetPath})

# Persist MAST_PROJECT machine-wide so the mast-unit NSSM service (and any process)
# resolves the role-based config path C:\WIS\<role>.toml. config-bootstrap runs at
# order 150, before mast (2200) installs/starts the service, so the service inherits it.
[Environment]::SetEnvironmentVariable('MAST_PROJECT', ${Role}, 'Machine')
${env:MAST_PROJECT} = ${Role}
Write-CfgLog ("Set MAST_PROJECT={0} (Machine)." -f ${Role})

Write-CfgLog 'config-bootstrap complete.'
exit 0
