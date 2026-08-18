<#
.SYNOPSIS
    Make the pinned PSScriptAnalyzer importable, and print how.

.DESCRIPTION
    THE PIN LIVES HERE. CI and every workstation import the same version through
    this script, so "green" means the same thing in both places -- the same reason
    ruff and basedpyright are pinned in requirements-dev.txt. The default rule set
    changes between PSSA releases; the version is part of the configuration.

    Two install paths, because one of them does not work where it is needed most:

    1. Install-Module from PSGallery. Works on the CI runners.
    2. Direct .nupkg download, extracted under $env:LOCALAPPDATA\pssa. Needed on
       the prov workstation, where PowerShellGet's NuGet-client bootstrap dies
       behind bcproxy with a NullReferenceException from
       Install-NuGetClientBinaries. That is not a proxy misconfiguration to fix --
       a .nupkg is a zip, and fetching it directly skips the whole provider
       bootstrap.

    Writes nothing to the repo and installs nothing machine-wide.

.OUTPUTS
    The path to import, i.e. what Import-Module should be given.
#>
[CmdletBinding()]
param(
    # Prefer the direct download even if Install-Module might work.
    [switch]${NoGallery}
)

${ErrorActionPreference} = 'Stop'
${PssaVersion} = '1.25.0'

function Get-InstalledPssaPath {
    param([string]${Version})
    ${m} = Get-Module -ListAvailable PSScriptAnalyzer |
        Where-Object { $_.Version.ToString() -eq ${Version} } |
        Select-Object -First 1
    if ($null -ne ${m}) { return ${m}.Path }
    ${local} = Join-Path (Join-Path ${env:LOCALAPPDATA} 'pssa') 'PSScriptAnalyzer.psd1'
    if (Test-Path -LiteralPath ${local}) {
        ${manifest} = Import-PowerShellDataFile -Path ${local}
        if (${manifest}.ModuleVersion -eq ${Version}) { return ${local} }
    }
    return $null
}

${found} = Get-InstalledPssaPath -Version ${PssaVersion}
if ($null -ne ${found}) {
    Write-Host ("PSScriptAnalyzer {0} already available" -f ${PssaVersion})
    ${found}
    exit 0
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not ${NoGallery}) {
    try {
        Write-Host ("installing PSScriptAnalyzer {0} from PSGallery" -f ${PssaVersion})
        Install-Module PSScriptAnalyzer -RequiredVersion ${PssaVersion} -Scope CurrentUser -Force -AllowClobber
        ${found} = Get-InstalledPssaPath -Version ${PssaVersion}
        if ($null -ne ${found}) { ${found}; exit 0 }
    } catch {
        Write-Host ("PSGallery install failed ({0}); falling back to the direct download" -f $_.Exception.GetType().Name)
    }
}

${dest} = Join-Path ${env:LOCALAPPDATA} 'pssa'
${nupkg} = Join-Path ${env:TEMP} ("pssa-{0}.zip" -f ${PssaVersion})
${url} = ("https://www.powershellgallery.com/api/v2/package/PSScriptAnalyzer/{0}" -f ${PssaVersion})
if (Test-Path -LiteralPath ${dest}) { Remove-Item -LiteralPath ${dest} -Recurse -Force }
New-Item -ItemType Directory -Force -Path ${dest} | Out-Null
Write-Host ("downloading {0}" -f ${url})
Invoke-WebRequest -Uri ${url} -OutFile ${nupkg} -UseBasicParsing
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory(${nupkg}, ${dest})
Remove-Item -LiteralPath ${nupkg} -Force -ErrorAction SilentlyContinue

${found} = Get-InstalledPssaPath -Version ${PssaVersion}
if ($null -eq ${found}) {
    throw ("PSScriptAnalyzer {0} still not importable after the direct download to {1}" -f ${PssaVersion}, ${dest})
}
${found}
