# Unit tests for build/build-licenses-lib.ps1 -- the NoMachine certificate guards.
#
# The expiry verdict is deliberately a pure function of (raw expiry, now), so
# every state can be tested with synthetic dates. That matters more than usual
# here: the live set expires 2027-07-01, so the 'expiring' branch would not fire
# in reality until 2027-05-02 and would otherwise run for the first time in
# production, eight months after it was written.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\build-licenses-lib.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\..\build\build-licenses-lib.ps1')

$NOW = [datetime]'2026-08-25 12:00:00'

Describe 'ConvertFrom-MastLicenseExpiry' {

    It 'parses the format NoMachine actually writes' {
        # Leading weekday and a timezone abbreviation, neither of which .NET takes.
        (ConvertFrom-MastLicenseExpiry -Raw 'Thu Jul 01 15:47:19 CEST 2027').Year | Should Be 2027
    }

    It 'returns MinValue for something it cannot parse' {
        ConvertFrom-MastLicenseExpiry -Raw 'sometime next year' | Should Be ([datetime]::MinValue)
    }

    It 'returns MinValue for an empty field' {
        ConvertFrom-MastLicenseExpiry -Raw '' | Should Be ([datetime]::MinValue)
    }
}

Describe 'Test-MastLicenseExpiry' {

    It 'passes a certificate with plenty of life left' {
        $v = Test-MastLicenseExpiry -RawExpiry 'Thu Jul 01 15:47:19 CEST 2027' -Now $NOW
        $v.State | Should Be 'ok'
        ($v.DaysLeft -gt 60) | Should Be $true
    }

    It 'warns inside the renewal window' {
        $v = Test-MastLicenseExpiry -RawExpiry 'Thu Oct 01 12:00:00 CEST 2026' -Now $NOW
        $v.State | Should Be 'expiring'
        $v.Message | Should Match 'lead time'
    }

    It 'treats the exact threshold as expiring, not ok' {
        # 60 days out with WarnDays 60: inside the window, inclusive.
        $v = Test-MastLicenseExpiry -RawExpiry 'Fri Oct 24 12:00:00 CEST 2026' -Now $NOW -WarnDays 60
        $v.State | Should Be 'expiring'
    }

    It 'reports the real expired set as expired' {
        # LI07W00084 -- the 2025 certificates that reached mast06 and mast07.
        $v = Test-MastLicenseExpiry -RawExpiry 'Wed Jul 01 14:35:25 CEST 2026' -Now $NOW
        $v.State | Should Be 'expired'
        $v.Message | Should Match 'EXPIRED'
    }

    It 'reports an unreadable expiry as unknown rather than fine' {
        # Cannot verify is not the same as verified good; this one warns.
        (Test-MastLicenseExpiry -RawExpiry 'garbage' -Now $NOW).State | Should Be 'unknown'
    }

    It 'reports a missing expiry field as unknown' {
        (Test-MastLicenseExpiry -RawExpiry '' -Now $NOW).State | Should Be 'unknown'
    }
}

Describe 'Assert-MastLicenseIsShippable' {

    function New-LicFile {
        param([string]$Expiry, [string]$Sub = 'LI06X02775')
        $p = Join-Path $env:TEMP ("mast-lic-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".lic")
        @(
            '----- Begin subscription data -----'
            'Product:               NoMachine Enterprise Desktop Subscription Pack'
            "Subscription Id:       $Sub"
            "Expiry:                $Expiry"
        ) | Set-Content -LiteralPath $p -Encoding ASCII
        return $p
    }

    It 'throws rather than ship an expired certificate' {
        # An expired certificate does not degrade NoMachine, it stops it: the
        # server refuses connections outright.
        $p = New-LicFile -Expiry 'Wed Jul 01 14:35:25 CEST 2026'
        try { { Assert-MastLicenseIsShippable -LicensePath $p -HostName 'mast08' } | Should Throw }
        finally { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }

    It 'ships a current certificate without complaint' {
        $p = New-LicFile -Expiry 'Thu Jul 01 15:47:19 CEST 2027'
        try { (Assert-MastLicenseIsShippable -LicensePath $p -HostName 'mast08').State | Should Be 'ok' }
        finally { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }

    It 'names the subscription and the host when it refuses' {
        # The message has to say which certificate and which unit, or an
        # operator with ten identically-named files learns nothing.
        $p = New-LicFile -Expiry 'Wed Jul 01 14:35:25 CEST 2026' -Sub 'LI07W00084'
        try {
            $msg = ''
            try { Assert-MastLicenseIsShippable -LicensePath $p -HostName 'mast08' } catch { $msg = $_.Exception.Message }
            $msg | Should Match 'LI07W00084'
            $msg | Should Match 'mast08'
        } finally { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Assert-MastNoLicensesInAssets' {

    It 'accepts a directory holding only the allocation table and its README' {
        $d = Join-Path $env:TEMP ("mast-assets-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        try {
            'x' | Set-Content (Join-Path $d 'allocated.csv')
            'x' | Set-Content (Join-Path $d 'README.txt')
            { Assert-MastNoLicensesInAssets -AssetsLicenseDir $d } | Should Not Throw
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'throws when a certificate reappears beside the table' {
        # The ambiguous second home is exactly what put expired certificates on
        # mast06 and mast07: refreshed in the copy nobody ships.
        $d = Join-Path $env:TEMP ("mast-assets-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        try {
            'x' | Set-Content (Join-Path $d 'server-02.lic')
            { Assert-MastNoLicensesInAssets -AssetsLicenseDir $d } | Should Throw
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'is silent when the directory does not exist' {
        { Assert-MastNoLicensesInAssets -AssetsLicenseDir (Join-Path $env:TEMP 'no-such-dir-here') } | Should Not Throw
    }
}

Describe 'the real assets directory' {

    It 'holds no certificates' {
        $d = Join-Path $here '..\providers\nomachine\assets\licenses'
        { Assert-MastNoLicensesInAssets -AssetsLicenseDir $d } | Should Not Throw
    }
}
