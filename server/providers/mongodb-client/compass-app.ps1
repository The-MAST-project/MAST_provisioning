# Locate the MongoDB Compass build a unit actually runs.
#
# Compass ships Squirrel's Update.exe and updates itself from MongoDB's feed,
# so the version on a unit is whatever it last fetched -- not the version in
# assets/. mast07 carried app-1.43.0 (provisioned) and app-1.49.14 (self-
# fetched) side by side hours after provisioning. That drift is accepted (see
# docs/decisions/2026-08-23-compass-updates-itself-so-the-report-follows-the-unit.md);
# reporting the wrong one of the two is not.
#
# Dot-sourced by provide-mongodb-client.ps1 and verify-mongodb-client.ps1,
# which are staged flat into the same directory. Listed in module.json
# commandfiles so a change here is drift the driver targets.

function Get-MastCompassVersionFromName {
    <#
    .SYNOPSIS
      Leading dotted-numeric version out of an app dir name or installer filename.
    .DESCRIPTION
      'app-1.49.14' -> 1.49.14, 'mongodb-compass-1.43.0-win32-x64.exe' -> 1.43.0.
      Returns $null when there is no version to read, which the callers report
      rather than guess at. A prerelease suffix ('app-1.44.0-beta.1') yields the
      numeric part; Compass's release channels are not otherwise modelled.
    #>
    param([string]${Name})

    if ([string]::IsNullOrWhiteSpace(${Name})) { return $null }
    ${m} = [regex]::Match(${Name}, '(?<v>\d+(?:\.\d+){1,3})')
    if (-not ${m}.Success) { return $null }
    try { return [version]${m}.Groups['v'].Value } catch { return $null }
}

function Get-MastCompassApp {
    <#
    .SYNOPSIS
      The live app-* directory under a Compass install root, plus everything else found.
    .DESCRIPTION
      Squirrel keeps each build in its own 'app-<version>' directory and marks a
      superseded one with a '.dead' file, deleting it on a later launch. So a
      drifted unit has two, and picking Get-ChildItem's first result picks the
      alphabetically-first name -- app-1.43.0 sorts before app-1.49.14, which is
      how the provider came to measure a dead tree while the unit ran a live one.

      Selection: skip the ones Squirrel marked dead, then take the highest
      version. '.dead' outranks the version comparison because it is Squirrel's
      own statement about which build is current, and a rollback marks the
      NEWER one dead.
    .OUTPUTS
      Path / Version / Name of the live build ($null when there is none), All
      (every candidate, newest first) and Superseded (the ones not selected).
    #>
    param([Parameter(Mandatory)][string]${CompassRoot})

    ${all} = @(
        Get-ChildItem -LiteralPath ${CompassRoot} -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
            ForEach-Object {
                [pscustomobject]@{
                    Name    = $_.Name
                    Path    = $_.FullName
                    Version = Get-MastCompassVersionFromName -Name $_.Name
                    IsDead  = Test-Path -LiteralPath (Join-Path $_.FullName '.dead')
                }
            } | Sort-Object -Property @{ Expression = 'Version'; Descending = $true },
                                      @{ Expression = 'Name';    Descending = $true }
    )

    ${live} = @(${all} | Where-Object { -not $_.IsDead -and $null -ne $_.Version })
    if (${live}.Count -eq 0) {
        # No parseable live name: an unreadable version is still an install, and
        # every candidate being dead means Squirrel has not finished a cleanup.
        # Report something rather than claim the install is absent.
        ${live} = @(${all} | Where-Object { -not $_.IsDead })
    }
    if (${live}.Count -eq 0) { ${live} = ${all} }

    ${chosen} = if (${live}.Count -gt 0) { ${live}[0] } else { $null }

    return [pscustomobject]@{
        Path       = if (${chosen}) { ${chosen}.Path } else { $null }
        Version    = if (${chosen}) { ${chosen}.Version } else { $null }
        Name       = if (${chosen}) { ${chosen}.Name } else { $null }
        All        = ${all}
        Superseded = @(${all} | Where-Object { $null -eq ${chosen} -or $_.Name -ne ${chosen}.Name })
    }
}

function Get-MastCompassPin {
    <#
    .SYNOPSIS
      The Compass version provisioning installs, read from the staged installer's filename.
    .DESCRIPTION
      Globbed rather than hard-coded so verify can name the pin without being
      edited alongside an asset bump. Returns $null Version when the installer
      is not staged, which is the normal case for a verify-only pass.
    #>
    param([Parameter(Mandatory)][string]${AssetsRoot})

    ${exe} = @(Get-ChildItem -LiteralPath ${AssetsRoot} -Filter 'mongodb-compass-*.exe' -File -ErrorAction SilentlyContinue |
                Sort-Object Name) | Select-Object -First 1
    return [pscustomobject]@{
        Path    = if (${exe}) { ${exe}.FullName } else { $null }
        Version = if (${exe}) { Get-MastCompassVersionFromName -Name ${exe}.Name } else { $null }
    }
}
