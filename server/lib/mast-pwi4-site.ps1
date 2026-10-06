#requires -Version 5.1
# The one statement of "what site does each copy say, and do they agree" for PWI4.
# Dot-sourced by the pwi4-site provider (which aligns the live PWI4.cfg) and its verify.
#
# A site lives in four places on a unit: C:\WIS\config.toml [location] (the boot-time
# mirror of the control DB 'sites' document, cross-checked by MAST_common at app start),
# the staged and the live PWI4.cfg, and the pointing model DefaultModel.pxp, which PWI4
# stamps with whatever PWI4.cfg said when the model was built. PWI4 refuses to load a
# model whose site differs from its configured one (#209).

${script:MastPwi4SettingsDir} = 'C:\Users\mast\Documents\PlaneWave Instruments\PWI4\Settings'
${script:MastPwi4ModelPath}   = 'C:\Users\mast\Documents\PlaneWave Instruments\PWI4\Mount\DefaultModel.pxp'

# PWI4 re-rounds the values it writes back (30.05301166519461 comes back as
# 30.0530116651946), so copies are compared as numbers, never as strings.
# 1e-9 degrees is about 0.004 milliarcseconds: float noise only.
${script:MastSiteDegreesTolerance} = 1e-9
${script:MastSiteMetersTolerance}  = 0.01

${script:MastInvariant} = [System.Globalization.CultureInfo]::InvariantCulture

function ConvertTo-MastSiteNumber {
    param([Parameter(Mandatory)][string]${Text}, [Parameter(Mandatory)][string]${What})
    ${value} = 0.0
    if (-not [double]::TryParse(${Text}.Trim(), [System.Globalization.NumberStyles]::Float, ${script:MastInvariant}, [ref]${value})) {
        throw ("{0} is not a number: '{1}'" -f ${What}, ${Text})
    }
    return ${value}
}

function Get-MastTomlLocation {
    # The [location] table of C:\WIS\config.toml, as the raw strings (written verbatim
    # into PWI4.cfg) and as numbers (for comparing).
    param([Parameter(Mandatory)][string]${Path})
    ${content} = Get-Content -LiteralPath ${Path} -Raw
    ${location} = [ordered]@{}
    foreach (${key} in 'latitude', 'longitude', 'elevation') {
        ${m} = [regex]::Match(${content}, ('(?m)^\s*{0}\s*=\s*(.+?)\s*$' -f ${key}))
        if (-not ${m}.Success) { throw ("{0} has no '{1}' key" -f ${Path}, ${key}) }
        ${location}[${key}] = ${m}.Groups[1].Value.Trim().Trim('"')
    }
    return [pscustomobject]@{
        LatitudeText  = ${location}['latitude']
        LongitudeText = ${location}['longitude']
        HeightText    = ${location}['elevation']
        Latitude      = ConvertTo-MastSiteNumber -Text ${location}['latitude'] -What "${Path} latitude"
        Longitude     = ConvertTo-MastSiteNumber -Text ${location}['longitude'] -What "${Path} longitude"
        Height        = ConvertTo-MastSiteNumber -Text ${location}['elevation'] -What "${Path} elevation"
    }
}

function Get-MastPwi4CfgSite {
    # Latitude / Longitude / HeightMeters from an aligned PWI4.cfg ("Field = value").
    param([Parameter(Mandatory)][string]${Path})
    ${fields} = @{}
    foreach (${line} in (Get-Content -LiteralPath ${Path})) {
        ${m} = [regex]::Match(${line}, '^\s*(Latitude|Longitude|HeightMeters)\s*=\s*(.*?)\s*$')
        if (${m}.Success) { ${fields}[${m}.Groups[1].Value] = ${m}.Groups[2].Value }
    }
    foreach (${key} in 'Latitude', 'Longitude', 'HeightMeters') {
        if (-not ${fields}.ContainsKey(${key})) { throw ("{0} has no {1} field" -f ${Path}, ${key}) }
    }
    return [pscustomobject]@{
        Latitude  = ConvertTo-MastSiteNumber -Text ${fields}['Latitude'] -What "${Path} Latitude"
        Longitude = ConvertTo-MastSiteNumber -Text ${fields}['Longitude'] -What "${Path} Longitude"
        Height    = ConvertTo-MastSiteNumber -Text ${fields}['HeightMeters'] -What "${Path} HeightMeters"
    }
}

function Get-MastPxpSite {
    # The site a pointing model was built at: the two lines after
    # "Latitude, Longitude, TimeZone, DST:" in DefaultModel.pxp. $null if the file
    # carries no such block.
    param([Parameter(Mandatory)][string]${Path})
    ${lines} = @(Get-Content -LiteralPath ${Path})
    ${i} = [array]::IndexOf(${lines}, 'Latitude, Longitude, TimeZone, DST:')
    if (${i} -lt 0 -or ${i} + 2 -ge ${lines}.Count) { return $null }
    return [pscustomobject]@{
        Latitude  = ConvertTo-MastSiteNumber -Text ${lines}[${i} + 1] -What "${Path} model latitude"
        Longitude = ConvertTo-MastSiteNumber -Text ${lines}[${i} + 2] -What "${Path} model longitude"
    }
}

function Test-MastSiteMatch {
    # Same latitude and longitude within MastSiteDegreesTolerance, and, when both sides
    # carry one, the same height within MastSiteMetersTolerance. A pointing model
    # records no height, so a model is compared on latitude and longitude only.
    param([Parameter(Mandatory)]${A}, [Parameter(Mandatory)]${B})
    if ([math]::Abs(${A}.Latitude - ${B}.Latitude) -gt ${script:MastSiteDegreesTolerance}) { return $false }
    if ([math]::Abs(${A}.Longitude - ${B}.Longitude) -gt ${script:MastSiteDegreesTolerance}) { return $false }
    ${aHasHeight} = ${A}.PSObject.Properties.Match('Height').Count -gt 0
    ${bHasHeight} = ${B}.PSObject.Properties.Match('Height').Count -gt 0
    if (${aHasHeight} -and ${bHasHeight} -and [math]::Abs(${A}.Height - ${B}.Height) -gt ${script:MastSiteMetersTolerance}) { return $false }
    return $true
}

function Format-MastSite {
    param([Parameter(Mandatory)]${Site})
    ${text} = 'lat {0} lon {1}' -f ${Site}.Latitude.ToString('R', ${script:MastInvariant}), ${Site}.Longitude.ToString('R', ${script:MastInvariant})
    if (${Site}.PSObject.Properties.Match('Height').Count -gt 0) { ${text} += (' height {0}' -f ${Site}.Height.ToString('R', ${script:MastInvariant})) }
    return ${text}
}

function Set-MastPwi4CfgField {
    # Overwrite "<Field> = <value>" in an aligned PWI4 .cfg, keeping the key and its
    # padding so the file stays aligned. Appends the key if it is absent. PWI4 cfgs are
    # ASCII. provide-instrument-profiles.ps1 has its own copy of this as Set-CfgField.
    param(
        [Parameter(Mandatory)][string]${Path},
        [Parameter(Mandatory)][string]${Field},
        [Parameter(Mandatory)][string]${Value}
    )
    ${re} = '^(\s*' + [regex]::Escape(${Field}) + '\s*=\s*).*$'
    ${found} = $false
    ${out} = @()
    foreach (${line} in (Get-Content -LiteralPath ${Path})) {
        if (${line} -match ${re}) {
            ${found} = $true
            ${out} += (${matches}[1] + ${Value})
        } else {
            ${out} += ${line}
        }
    }
    if (-not ${found}) { ${out} += ('{0} = {1}' -f ${Field}, ${Value}) }
    Set-Content -LiteralPath ${Path} -Value ${out} -Encoding ASCII
}
