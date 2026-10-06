#requires -Version 5.1
# Read-only snapshot of a unit's PWI4 site, printed as one JSON object between marker
# lines (MAST_provisioning#209). tools/fleet-drift-report.py uploads this file with
# mast-pwi4-site.ps1 and runs it. The comparisons are made here, with the same
# Test-MastSiteMatch the pwi4-site provider uses, so the report and the provider cannot
# disagree about what "the same site" means.
[CmdletBinding()]
param(
    [string]${UnitToml} = 'C:\WIS\config.toml'
)

${ErrorActionPreference} = 'Stop'

if (-not (Get-Command Test-MastSiteMatch -ErrorAction SilentlyContinue)) {
    . (Join-Path ${PSScriptRoot} 'mast-pwi4-site.ps1')
}

${BEGIN_MARK} = '====MAST-PWI4-SITE-PROBE-BEGIN===='
${END_MARK} = '====MAST-PWI4-SITE-PROBE-END===='

function ConvertTo-SiteObject {
    param(${Site})
    if (${null} -eq ${Site}) { return ${null} }
    ${o} = [ordered]@{ latitude = ${Site}.Latitude; longitude = ${Site}.Longitude }
    if (${Site}.PSObject.Properties.Match('Height').Count -gt 0) { ${o}['height'] = ${Site}.Height }
    return ${o}
}

${config} = if (Test-Path -LiteralPath ${UnitToml}) { Get-MastTomlLocation -Path ${UnitToml} } else { ${null} }
${cfgPath} = Join-Path ${script:MastPwi4SettingsDir} 'PWI4.cfg'
${cfg} = if (Test-Path -LiteralPath ${cfgPath}) { Get-MastPwi4CfgSite -Path ${cfgPath} } else { ${null} }
${modelPresent} = Test-Path -LiteralPath ${script:MastPwi4ModelPath}
${model} = if (${modelPresent}) { Get-MastPxpSite -Path ${script:MastPwi4ModelPath} } else { ${null} }

${result} = [ordered]@{
    config               = ConvertTo-SiteObject ${config}
    cfg                  = ConvertTo-SiteObject ${cfg}
    model_present        = [bool]${modelPresent}
    model                = ConvertTo-SiteObject ${model}
    cfg_matches_config   = if (${config} -and ${cfg}) { [bool](Test-MastSiteMatch -A ${cfg} -B ${config}) } else { ${null} }
    model_matches_config = if (${config} -and ${model}) { [bool](Test-MastSiteMatch -A ${model} -B ${config}) } else { ${null} }
    pwi4_running         = [bool](@(Get-Process -Name 'PWI4' -ErrorAction SilentlyContinue).Count -gt 0)
}

Write-Output ${BEGIN_MARK}
Write-Output (${result} | ConvertTo-Json -Depth 4 -Compress)
Write-Output ${END_MARK}
