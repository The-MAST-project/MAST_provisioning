#requires -Version 5.1
# Align the live PWI4.cfg site (Latitude / Longitude / HeightMeters) with C:\WIS\config.toml
# [location], and say loudly when that orphans the unit's pointing model (#209).
#
# instrument-profiles writes the site into the STAGED PWI4.cfg, which reaches the live one
# only at the first mast logon. After that nothing re-asserted it: PWI4 rewrites its own
# cfg, the GUI edits it, and the fleet drifted to three different sites. This provider
# touches only those three fields of the live file, so per-unit COM bindings and the rest
# of the cfg are left as they are.
#
# PWI4 rewrites PWI4.cfg on exit, so a write while it runs would be lost: the provider
# refuses, and the module is retried on the next run.

[CmdletBinding()]
param(
    [string]${UnitToml} = 'C:\WIS\config.toml',
    # Overridable so the provider can be exercised against planted files (server/tests).
    [string]${Pwi4SettingsDir} = '',
    [string]${ModelPath} = '',
    [string]${Pwi4ProcessName} = 'PWI4'
)

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${siteLib} = Join-Path ${PSScriptRoot} 'mast-pwi4-site.ps1'
if (-not (Test-Path ${siteLib})) { ${siteLib} = Join-Path ${PSScriptRoot} '..\..\lib\mast-pwi4-site.ps1' }
. ${siteLib}
if (-not ${Pwi4SettingsDir}) { ${Pwi4SettingsDir} = ${script:MastPwi4SettingsDir} }
if (-not ${ModelPath}) { ${ModelPath} = ${script:MastPwi4ModelPath} }

${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} 'pwi4-site.log'

function Log {
    param([string]${Line})
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-pwi4-site.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    if (-not (Test-Path -LiteralPath ${UnitToml})) { throw ("{0} absent; config-bootstrap has not run" -f ${UnitToml}) }
    ${want} = Get-MastTomlLocation -Path ${UnitToml}
    Log ("Site from {0}: {1}" -f ${UnitToml}, (Format-MastSite -Site ${want}))

    ${cfg} = Join-Path ${Pwi4SettingsDir} 'PWI4.cfg'
    if (-not (Test-Path -LiteralPath ${cfg})) {
        Log ("{0} absent: the profiles have not been applied yet (first mast logon). The staged copy carries the site; nothing to align." -f ${cfg})
        Write-MastSmokeOk -Module 'pwi4-site' | Out-Null
        exit 0
    }

    ${have} = Get-MastPwi4CfgSite -Path ${cfg}
    Log ("Site in {0}: {1}" -f ${cfg}, (Format-MastSite -Site ${have}))

    if (Test-MastSiteMatch -A ${have} -B ${want}) {
        Log 'PWI4.cfg already carries the configured site; nothing written.'
    } else {
        ${pwi4} = @(Get-Process -Name ${Pwi4ProcessName} -ErrorAction SilentlyContinue)
        if (${pwi4}.Count -gt 0) {
            throw ("PWI4 is running (pid {0}) and rewrites PWI4.cfg on exit; close it and re-run. The site was not changed." -f ((${pwi4} | ForEach-Object { $_.Id }) -join ','))
        }
        ${backup} = '{0}.{1}.bak' -f ${cfg}, (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath ${cfg} -Destination ${backup}
        Log ("Backed up {0}" -f ${backup})
        Set-MastPwi4CfgField -Path ${cfg} -Field 'Latitude'     -Value ${want}.LatitudeText
        Set-MastPwi4CfgField -Path ${cfg} -Field 'Longitude'    -Value ${want}.LongitudeText
        Set-MastPwi4CfgField -Path ${cfg} -Field 'HeightMeters' -Value ${want}.HeightText
        ${after} = Get-MastPwi4CfgSite -Path ${cfg}
        if (-not (Test-MastSiteMatch -A ${after} -B ${want})) {
            throw ("PWI4.cfg reads back {0} after the write, not the configured site" -f (Format-MastSite -Site ${after}))
        }
        Log ("PWI4.cfg site changed from {0} to {1}." -f (Format-MastSite -Site ${have}), (Format-MastSite -Site ${after}))
    }

    if (Test-Path -LiteralPath ${ModelPath}) {
        ${model} = Get-MastPxpSite -Path ${ModelPath}
        if (${null} -eq ${model}) {
            Log ("[WARN] {0} carries no site block; cannot tell whether PWI4 will load it." -f ${ModelPath})
        } elseif (Test-MastSiteMatch -A ${model} -B ${want}) {
            Log ("Pointing model site matches: {0}" -f (Format-MastSite -Site ${model}))
        } else {
            Log ("[WARN] POINTING MODEL ORPHANED: {0} was built at {1}, but PWI4 is configured for {2}. PWI4 will refuse to load it and the mount will point on raw encoders until the model is rebuilt at this site (MAST_provisioning#209)." -f ${ModelPath}, (Format-MastSite -Site ${model}), (Format-MastSite -Site ${want}))
        }
    } else {
        Log ("No pointing model at {0}; the mount points on raw encoders until one is built." -f ${ModelPath})
    }

    Write-MastSmokeOk -Module 'pwi4-site' | Out-Null
    Log 'pwi4-site provisioning complete.'
    exit 0
}
catch {
    Log ("FAILED: {0}" -f $_)
    exit 1
}
