# What a NoMachine expiry date MEANS. Shared, deliberately: this verdict is
# needed in two places that cannot see each other's code -- build/build-mast.ps1
# on the prov server, deciding whether to ship a certificate, and
# verify-nomachine.ps1 on a unit, reading what nxserver actually loaded.
#
# One home rather than two copies. A threshold duplicated across the build and
# the unit is a threshold that drifts, and drift between copies is exactly how
# the certificates themselves went wrong (MAST_provisioning#154).
#
# Dot-sourced by build/build-licenses-lib.ps1 on the server, and shipped to
# units as a repofiles entry of the nomachine module.

#: Lead time on a renewal. Inside this window a certificate still works and
#: still builds; it warns, because provisioning cannot buy a subscription and
#: failing over a purchasing timescale blocks work nobody on the run can
#: unblock. Expiry itself is a different matter and does fail.
$script:MastLicenseWarnDays = 60

#: Closer than this and a warning is no longer proportionate -- at a month out
#: the renewal needs to be in progress, not noticed. Still never fails.
$script:MastLicenseUrgentDays = 30

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
