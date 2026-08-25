# NoMachine certificate helpers for build-mast.ps1. Dot-sourceable and
# side-effect-free so server/tests/build-licenses-lib.Tests.ps1 can exercise
# them without running a build, the same arrangement build-staging-lib.ps1 and
# build-bootstrap-lib.ps1 have.
#
# WHY THIS FILE EXISTS: certificates ship from vault\nomachine-licenses (the
# gitignored credential store, which is $LicensesRoot in build-mast.ps1), while
# the allocation table and the documentation live in
# server\providers\nomachine\assets\licenses. For a while a second, unread copy
# of the ten certificates also sat in that assets directory -- untracked, not
# ignored, and beside the README telling you to keep them current. Refresh the
# copy nobody ships and everything looks right while units receive the old set;
# that is the shape of the 2026-08-23 incident that put expired certificates on
# mast06 and mast07 (MAST_provisioning#154).
#
# Two guards, both at build time, because the build is the last place that sees
# a certificate before it reaches a unit:
#
#   Assert-MastNoLicensesInAssets  -- the assets directory holds no *.lic at all,
#                                     so the ambiguous second home cannot re-form.
#   Test-MastLicenseExpiry         -- the certificate about to ship is not expired.
#
# The second is the one that would have stopped the original incident outright.
# It reads the file the build is copying, before any transfer, so it does not
# depend on the unit-side verify ever running -- and in that incident the
# unit-side check demonstrably never got the chance.

#: Lead time on a renewal. A certificate inside this window still builds; it
#: warns, because provisioning cannot buy a subscription and failing a build
#: over a purchasing timescale would block unit work nobody on the run can
#: unblock. Expiry itself is a different matter and fails.
$script:MastLicenseWarnDays = 60

function Get-MastLicenseField {
    <#
    .SYNOPSIS
      One field out of a NoMachine .lic (a signed text file with a plain header).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Field
    )
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $m = Select-String -Path $Path -Pattern ('^{0}:\s*(.+?)\s*$' -f [regex]::Escape($Field)) | Select-Object -First 1
    if (-not $m) { return '' }
    return $m.Matches[0].Groups[1].Value.Trim()
}

function ConvertFrom-MastLicenseExpiry {
    <#
    .SYNOPSIS
      Parse a NoMachine expiry string, or [datetime]::MinValue if it will not parse.
    .DESCRIPTION
      The field reads e.g. 'Thu Jul 01 15:47:19 CEST 2027'. .NET parses neither
      the leading weekday nor the timezone abbreviation, so both are stripped --
      the same treatment verify-nomachine.ps1 gives the string nxserver reports.
      Timezone is dropped rather than honoured because the thresholds here are
      days, where a few hours cannot change the verdict.
    #>
    [CmdletBinding()]
    param([string]$Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return [datetime]::MinValue }
    $s = [regex]::Replace($Raw, '^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*\s+', '')
    $s = [regex]::Replace($s, '\s+[A-Z]{2,5}\s+(\d{4})$', ' $1')
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParseExact($s, 'MMM dd HH:mm:ss yyyy',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed
    }
    return [datetime]::MinValue
}

function Test-MastLicenseExpiry {
    <#
    .SYNOPSIS
      Verdict on a certificate the build is about to ship.
    .DESCRIPTION
      Pure: takes the raw expiry string and 'now', returns State / Message /
      DaysLeft. States:
        ok        -- more than the warn window remains
        expiring  -- inside the window; builds, but says so
        expired   -- past; the build must not ship it
        unknown   -- no expiry field, or one that will not parse. Warns rather
                     than passing silently: cannot verify is not the same as
                     fine, and a certificate whose expiry cannot be read is
                     exactly the case worth a human glance.
    #>
    [CmdletBinding()]
    param(
        [string]$RawExpiry,
        [datetime]$Now = (Get-Date),
        [int]$WarnDays = $script:MastLicenseWarnDays
    )

    $expiry = ConvertFrom-MastLicenseExpiry -Raw $RawExpiry
    if ($expiry -eq [datetime]::MinValue) {
        return [pscustomobject]@{
            State = 'unknown'; DaysLeft = $null
            Message = ("expiry could not be read from the certificate (got '{0}')" -f $RawExpiry)
        }
    }
    $days = [int][math]::Floor(($expiry - $Now).TotalDays)
    if ($expiry -lt $Now) {
        return [pscustomobject]@{
            State = 'expired'; DaysLeft = $days
            Message = ("certificate EXPIRED on {0} ({1} day(s) ago)" -f $RawExpiry, [math]::Abs($days))
        }
    }
    if ($days -le $WarnDays) {
        return [pscustomobject]@{
            State = 'expiring'; DaysLeft = $days
            Message = ("certificate expires in {0} day(s), on {1} -- renewal takes lead time, start it now" -f $days, $RawExpiry)
        }
    }
    return [pscustomobject]@{
        State = 'ok'; DaysLeft = $days
        Message = ("certificate valid for {0} more day(s) (expires {1})" -f $days, $RawExpiry)
    }
}

function Assert-MastLicenseIsShippable {
    <#
    .SYNOPSIS
      Fail the build rather than ship an expired certificate to a unit.
    .DESCRIPTION
      An expired certificate does not degrade NoMachine, it stops it: the server
      refuses connections outright, so a unit that receives one loses its remote
      desktop the moment it applies it. Shipping that knowingly is worse than
      failing the build, and unlike a renewal date the build CAN act on it --
      the fix is to restore the current set, which is a local operation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LicensePath,
        [Parameter(Mandatory)][string]$HostName
    )

    $raw = Get-MastLicenseField -Path $LicensePath -Field 'Expiry'
    $sub = Get-MastLicenseField -Path $LicensePath -Field 'Subscription Id'
    $v = Test-MastLicenseExpiry -RawExpiry $raw
    $label = ("{0} ({1}) for {2}" -f (Split-Path $LicensePath -Leaf), $(if ($sub) { $sub } else { 'no subscription id' }), $HostName)

    switch ($v.State) {
        'expired' {
            throw ("Refusing to ship {0}: {1}. Restore the current set into the certificate store; see server\providers\nomachine\assets\licenses\README.txt." -f $label, $v.Message)
        }
        'expiring' { Write-Warning ("[build-mast] {0}: {1}" -f $label, $v.Message) }
        'unknown'  { Write-Warning ("[build-mast] {0}: {1}" -f $label, $v.Message) }
        default    { Write-Host ("[build-mast] {0}: {1}" -f $label, $v.Message) }
    }
    return $v
}

function Assert-MastNoLicensesInAssets {
    <#
    .SYNOPSIS
      Fail the build if certificates reappear beside the allocation table.
    .DESCRIPTION
      The assets directory holds allocated.csv and README.txt -- both tracked,
      neither secret. Certificates live only in the gitignored store the build
      reads. A copy here is read by nothing, so it can drift from what ships
      without any symptom, which is how an expired set survived a refresh of
      "the licences" and reached two units.

      Deliberately a build failure rather than a .gitignore rule: ignoring the
      files would hide a stray copy silently, which is the same failure with
      better manners. This says so, out loud, at the moment it would matter.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AssetsLicenseDir)

    if (-not (Test-Path -LiteralPath $AssetsLicenseDir)) { return }
    $stray = @(Get-ChildItem -LiteralPath $AssetsLicenseDir -Filter '*.lic' -File -ErrorAction SilentlyContinue)
    if ($stray.Count -gt 0) {
        throw ("{0} certificate(s) found in {1}: {2}. Certificates live ONLY in the vault store the build reads; a copy here is shipped to nobody and drifts silently. Delete them (the store is the source of truth) -- see that directory's README.txt." -f `
            $stray.Count, $AssetsLicenseDir, (($stray | ForEach-Object { $_.Name }) -join ', '))
    }
}
