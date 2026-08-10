param(
    # Site whose profile (sites/<Site>.toml) becomes this machine's bootstrap config.
    # Injected by build-mast.ps1 -Site (mirrors the proxy/astrometry command tweaks).
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]${Site},
    [string]${AssetsRoot} = '.',
    # Machine role -> the `machine_role` field written into C:\WIS\config.toml. Units only today.
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

# Deploy to the fixed path C:\WIS\config.toml. The site profile is per-site and carries
# no role, so the machine's role is injected as a top-level `machine_role` key, prepended
# ahead of the profile body (a top-level key must precede the [location] table). MAST_common
# reads the file utf-8-sig, so the BOM that Set-Content -Encoding UTF8 writes is tolerated.
# There is no MAST_PROJECT env var anymore -- the role lives in the file.
${targetPath} = 'C:\WIS\config.toml'
${wisDir} = Split-Path -Parent ${targetPath}
New-Item -ItemType Directory -Path ${wisDir} -Force | Out-Null
${profileBody} = Get-Content -LiteralPath ${siteFile} -Raw
${configBody} = ('machine_role = "{0}"{1}{2}' -f ${Role}, [Environment]::NewLine, ${profileBody})
Set-Content -LiteralPath ${targetPath} -Encoding UTF8 -Value ${configBody}
Write-CfgLog ("Wrote {0} (machine_role={1})" -f ${targetPath}, ${Role})

Write-CfgLog 'config-bootstrap complete.'
exit 0
