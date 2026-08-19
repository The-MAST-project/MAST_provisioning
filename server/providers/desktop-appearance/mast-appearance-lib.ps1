# The facts the unit background shows, derived once so the renderer and the verify
# cannot disagree about them.
#
# provide-desktop-appearance.ps1 renders from Get-MastAppearanceFields; then
# verify-desktop-appearance.ps1 calls the same function and compares the result to
# what the sidecar recorded. That is what makes the staleness check meaningful: two
# independent readings of "what should be on the image" would only ever prove that
# two copies of the formatting code agree with each other.
#
# This file defines functions only -- dot-sourcing it reads nothing.

#: Site codes are what config.toml carries ('ns'); an operator glancing at a screen
#: wants the place. Kept here rather than added to config-bootstrap's sites\*.toml,
#: because the app cross-checks that file against the controller's MongoDB 'sites'
#: document at startup and a new key there is a risk taken for a wallpaper label.
#: An unknown code renders as itself rather than failing.
${script:MastSiteDisplayNames} = @{
    ns  = 'Neot Smadar'
    wis = 'Weizmann Institute'
}

function Get-MastTomlValue {
    # Light single-key reader for the flat top-level and [location] keys this needs.
    # Same regex approach as verify-config-bootstrap and provide-instrument-profiles;
    # no tomllib dependency for four scalars.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]${Content}, [Parameter(Mandatory)][string]${Key})

    ${match} = [regex]::Match(${Content}, ('(?m)^\s*{0}\s*=\s*(.+?)\s*$' -f [regex]::Escape(${Key})))
    if (${match}.Success) { return ${match}.Groups[1].Value.Trim().Trim('"') }
    return $null
}

function Get-MastSiteDisplayName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]${SiteCode})

    if (${script:MastSiteDisplayNames}.ContainsKey(${SiteCode})) { return ${script:MastSiteDisplayNames}[${SiteCode}] }
    return ${SiteCode}
}

function Format-MastCoordinates {
    # '30.0530 N   35.0408 E' -- four decimals is about 11 m, which is all a
    # wallpaper needs from a value config.toml carries to 17 places.
    #
    # Formatted through InvariantCulture on purpose: '{0:F4}' honours the current
    # culture, and a comma decimal separator would turn the coordinates into
    # nonsense on a machine whose regional format drifted. Bootstrap pins en-US,
    # but this does not depend on that having worked.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]${Latitude}, [Parameter(Mandatory)][AllowEmptyString()][string]${Longitude})

    ${lat} = 0.0
    ${lon} = 0.0
    if (-not [double]::TryParse(${Latitude}, [ref]${lat}))  { return '' }
    if (-not [double]::TryParse(${Longitude}, [ref]${lon})) { return '' }

    ${northSouth} = 'N'
    if (${lat} -lt 0) { ${northSouth} = 'S' }
    ${eastWest} = 'E'
    if (${lon} -lt 0) { ${eastWest} = 'W' }

    return [string]::Format([cultureinfo]::InvariantCulture, '{0:F4} {1}   {2:F4} {3}',
        [math]::Abs(${lat}), ${northSouth}, [math]::Abs(${lon}), ${eastWest})
}

function Get-MastPayloadStamp {
    # The provisioning commit a unit was last given, short form: 'a1b2c3d'.
    #
    # Read from the build-manifest.json that came WITH the payload being installed,
    # not from installed-manifest.json -- at order 2750 the installed manifest still
    # describes the PREVIOUS run, so it would stamp the image with the version the
    # machine is being moved off.
    #
    # git_sha, not built_at: the driver rebuilds the payload on every run, so a
    # built_at stamp would differ on every single run and this module would drift
    # forever. The commit changes when what a unit receives changes, which is the
    # thing worth naming. Same convention as module_versions, where the provisioning
    # SHA is the human-readable field rather than the drift signal.
    #
    # Empty when there is no manifest to read -- an isolated provider run, not a
    # failure.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]${BuildManifestPath})

    if (-not (Test-Path -LiteralPath ${BuildManifestPath})) { return '' }
    ${manifest} = Get-Content -LiteralPath ${BuildManifestPath} -Raw | ConvertFrom-Json
    if (-not ${manifest}.git_sha) { return '' }
    return ${manifest}.git_sha.Substring(0, [math]::Min(7, ${manifest}.git_sha.Length))
}

function Get-MastAppearanceFields {
    # Everything the background states, as the renderer wants it: presentation-ready
    # strings, so the renderer holds no opinion about where any of it came from.
    #
    # site keeps the raw code alongside the display name so verify catches BOTH a
    # changed config and a changed display-name map -- comparing only the name would
    # pass after the map moved, and comparing only the code would pass after the
    # image was rendered from a name that no longer applies.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]${UnitToml},
        [Parameter(Mandatory)][AllowEmptyString()][string]${BuildManifestPath}
    )

    ${site} = ''
    ${coordinates} = ''
    if (Test-Path -LiteralPath ${UnitToml}) {
        ${toml} = Get-Content -LiteralPath ${UnitToml} -Raw
        ${tomlSite} = Get-MastTomlValue -Content ${toml} -Key 'site'
        if (${tomlSite}) { ${site} = ${tomlSite} }
        ${coordinates} = Format-MastCoordinates `
            -Latitude  ([string](Get-MastTomlValue -Content ${toml} -Key 'latitude')) `
            -Longitude ([string](Get-MastTomlValue -Content ${toml} -Key 'longitude'))
    }

    ${payload} = ''
    if (${BuildManifestPath}) { ${payload} = Get-MastPayloadStamp -BuildManifestPath ${BuildManifestPath} }

    return [ordered]@{
        computer_name = ${env:COMPUTERNAME}
        site          = ${site}
        site_name     = (Get-MastSiteDisplayName -SiteCode ${site})
        coordinates   = ${coordinates}
        payload       = ${payload}
    }
}
