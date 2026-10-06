#requires -Version 5.1
# Verify: the live PWI4.cfg site equals C:\WIS\config.toml [location] (#209). An orphaned
# pointing model is reported but does not fail the verify: rebuilding it needs sky, and
# provisioning cannot do that.

[CmdletBinding()]
param(
    [string]${UnitToml} = 'C:\WIS\config.toml',
    # Overridable so the provider can be exercised against planted files (server/tests).
    [string]${Pwi4SettingsDir} = '',
    [string]${ModelPath} = ''
)

${ErrorActionPreference} = 'Stop'
${siteLib} = Join-Path ${PSScriptRoot} 'mast-pwi4-site.ps1'
if (-not (Test-Path ${siteLib})) { ${siteLib} = Join-Path ${PSScriptRoot} '..\..\lib\mast-pwi4-site.ps1' }
. ${siteLib}
if (-not ${Pwi4SettingsDir}) { ${Pwi4SettingsDir} = ${script:MastPwi4SettingsDir} }
if (-not ${ModelPath}) { ${ModelPath} = ${script:MastPwi4ModelPath} }

try {
    ${want} = Get-MastTomlLocation -Path ${UnitToml}
    ${cfg} = Join-Path ${Pwi4SettingsDir} 'PWI4.cfg'
    if (-not (Test-Path -LiteralPath ${cfg})) {
        Write-Host ("[UNVERIFIABLE] {0} absent (profiles not applied yet); no live site to check." -f ${cfg})
        exit 2
    }
    ${have} = Get-MastPwi4CfgSite -Path ${cfg}
    if (-not (Test-MastSiteMatch -A ${have} -B ${want})) {
        Write-Host ("[FAIL] PWI4.cfg site {0} differs from {1} {2}" -f (Format-MastSite -Site ${have}), ${UnitToml}, (Format-MastSite -Site ${want}))
        exit 1
    }
    Write-Host ("[PASS] PWI4.cfg site matches {0}: {1}" -f ${UnitToml}, (Format-MastSite -Site ${have}))

    if (Test-Path -LiteralPath ${ModelPath}) {
        ${model} = Get-MastPxpSite -Path ${ModelPath}
        if (${null} -ne ${model} -and -not (Test-MastSiteMatch -A ${model} -B ${want})) {
            Write-Host ("[WARN] pointing model built at {0}; PWI4 will refuse it until it is rebuilt at this site" -f (Format-MastSite -Site ${model}))
        }
    }
    exit 0
}
catch {
    Write-Host ("[FAIL] {0}" -f $_)
    exit 1
}
