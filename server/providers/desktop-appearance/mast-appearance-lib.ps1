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

#: Every per-user value this provider owns, in one table, because three callers write
#: or read it and a second copy is how they drift: provide writes it into the mast hive
#: from the provisioning session, apply re-asserts it in that session at logon, and
#: verify compares what is deployed against it.
#:
#: The notification quieting below moved here from client\bootstrap-winrm.ps1 in
#: MAST_provisioning#106. Bootstrap wrote it to whichever hive it could reach and
#: reported success either way; more to the point, at bootstrap time the mast account
#: has been created seconds earlier and has no profile at all, so there was no hive to
#: write. Nothing is lost by moving it later -- provisioning runs long before a unit is
#: operated, and by then the profile exists.
#:
#: Types matter and are not interchangeable. WallpaperStyle and TileWallpaper are REG_SZ
#: -- written as DWORD they are ignored and the image lands centred and untiled.
${script:MastPersonalizeKey} = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
${script:MastDesktopKey}     = 'Control Panel\Desktop'
${script:MastPushKey}        = 'Software\Microsoft\Windows\CurrentVersion\PushNotifications'
${script:MastCdmKey}         = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

function Get-MastDesktopUserValues {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]${WallpaperPath})

    ${values} = @(
        # Dark theme: application chrome, then the shell (taskbar, Start).
        @{ SubKey = ${script:MastPersonalizeKey}; Name = 'AppsUseLightTheme';    Value = 0; Type = 'DWord' },
        @{ SubKey = ${script:MastPersonalizeKey}; Name = 'SystemUsesLightTheme'; Value = 0; Type = 'DWord' },
        # Background.
        @{ SubKey = ${script:MastDesktopKey}; Name = 'Wallpaper';      Value = ${WallpaperPath}; Type = 'String' },
        @{ SubKey = ${script:MastDesktopKey}; Name = 'WallpaperStyle'; Value = '10';             Type = 'String' },
        @{ SubKey = ${script:MastDesktopKey}; Name = 'TileWallpaper';  Value = '0';              Type = 'String' },
        # Toasts: nothing should pop up over an observing session.
        @{ SubKey = ${script:MastPushKey}; Name = 'ToastEnabled'; Value = 0; Type = 'DWord' }
    )

    # Content delivery: tips, spotlight, "Get started", app suggestions, the rotating
    # lock-screen image. All the same shape, so the names carry the whole difference.
    foreach (${name} in @(
            'SoftLandingEnabled',
            'SubscribedContent-338389Enabled',
            'SubscribedContent-310093Enabled',
            'SubscribedContent-338388Enabled',
            'RotatingLockScreenEnabled',
            'OemPreInstalledAppsEnabled',
            'PreInstalledAppsEnabled',
            'SilentInstalledAppsEnabled',
            'SystemPaneSuggestionsEnabled')) {
        ${values} += @{ SubKey = ${script:MastCdmKey}; Name = ${name}; Value = 0; Type = 'DWord' }
    }

    return ${values}
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

function Get-MastAppearanceFields {
    # Everything the background states, as the renderer wants it: presentation-ready
    # strings, so the renderer holds no opinion about where any of it came from.
    #
    # site keeps the raw code alongside the display name so verify catches BOTH a
    # changed config and a changed display-name map -- comparing only the name would
    # pass after the map moved, and comparing only the code would pass after the
    # image was rendered from a name that no longer applies.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]${UnitToml})

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

    return [ordered]@{
        computer_name = ${env:COMPUTERNAME}
        site          = ${site}
        site_name     = (Get-MastSiteDisplayName -SiteCode ${site})
        coordinates   = ${coordinates}
    }
}
