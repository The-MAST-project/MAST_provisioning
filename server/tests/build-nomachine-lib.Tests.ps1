# Unit tests for build/build-nomachine-lib.ps1 -- the NoMachine certificate guards.
#
# The expiry verdict is deliberately a pure function of (raw expiry, now), so
# every state can be tested with synthetic dates. That matters more than usual
# here: the live set expires 2027-07-01, so the 'expiring' branch would not fire
# in reality until 2027-05-02 and would otherwise run for the first time in
# production, eight months after it was written.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\build-nomachine-lib.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\..\build\build-nomachine-lib.ps1')

$NOW = [datetime]'2026-08-25 12:00:00'

Describe 'ConvertFrom-MastNoMachineExpiry' {

    It 'parses the format NoMachine actually writes' {
        # Leading weekday and a timezone abbreviation, neither of which .NET takes.
        (ConvertFrom-MastNoMachineExpiry -Raw 'Thu Jul 01 15:47:19 CEST 2027').Year | Should Be 2027
    }

    It 'returns MinValue for something it cannot parse' {
        ConvertFrom-MastNoMachineExpiry -Raw 'sometime next year' | Should Be ([datetime]::MinValue)
    }

    It 'returns MinValue for an empty field' {
        ConvertFrom-MastNoMachineExpiry -Raw '' | Should Be ([datetime]::MinValue)
    }
}

Describe 'Test-MastNoMachineExpiry' {

    It 'passes a certificate with plenty of life left' {
        $v = Test-MastNoMachineExpiry -RawExpiry 'Thu Jul 01 15:47:19 CEST 2027' -Now $NOW
        $v.State | Should Be 'ok'
        ($v.DaysLeft -gt 60) | Should Be $true
    }

    It 'warns inside the renewal window' {
        $v = Test-MastNoMachineExpiry -RawExpiry 'Thu Oct 01 12:00:00 CEST 2026' -Now $NOW
        $v.State | Should Be 'expiring'
        $v.Message | Should Match 'lead time'
    }

    It 'treats the exact threshold as expiring, not ok' {
        # 60 days out with WarnDays 60: inside the window, inclusive.
        $v = Test-MastNoMachineExpiry -RawExpiry 'Fri Oct 24 12:00:00 CEST 2026' -Now $NOW -WarnDays 60
        $v.State | Should Be 'expiring'
    }

    It 'reports the real expired set as expired' {
        # LI07W00084 -- the 2025 certificates that reached mast06 and mast07.
        $v = Test-MastNoMachineExpiry -RawExpiry 'Wed Jul 01 14:35:25 CEST 2026' -Now $NOW
        $v.State | Should Be 'expired'
        $v.Message | Should Match 'EXPIRED'
    }

    It 'reports an unreadable expiry as unknown rather than fine' {
        # Cannot verify is not the same as verified good; this one warns.
        (Test-MastNoMachineExpiry -RawExpiry 'garbage' -Now $NOW).State | Should Be 'unknown'
    }

    It 'reports a missing expiry field as unknown' {
        (Test-MastNoMachineExpiry -RawExpiry '' -Now $NOW).State | Should Be 'unknown'
    }
}

Describe 'Assert-MastNoMachineCertIsShippable' {

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
        try { { Assert-MastNoMachineCertIsShippable -LicensePath $p -HostName 'mast08' } | Should Throw }
        finally { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }

    It 'ships a current certificate without complaint' {
        $p = New-LicFile -Expiry 'Thu Jul 01 15:47:19 CEST 2027'
        try { (Assert-MastNoMachineCertIsShippable -LicensePath $p -HostName 'mast08').State | Should Be 'ok' }
        finally { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }

    It 'names the subscription and the host when it refuses' {
        # The message has to say which certificate and which unit, or an
        # operator with ten identically-named files learns nothing.
        $p = New-LicFile -Expiry 'Wed Jul 01 14:35:25 CEST 2026' -Sub 'LI07W00084'
        try {
            $msg = ''
            try { Assert-MastNoMachineCertIsShippable -LicensePath $p -HostName 'mast08' } catch { $msg = $_.Exception.Message }
            $msg | Should Match 'LI07W00084'
            $msg | Should Match 'mast08'
        } finally { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Assert-MastNoNoMachineCertsInAssets' {

    It 'accepts a directory holding only the allocation table and its README' {
        $d = Join-Path $env:TEMP ("mast-assets-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        try {
            'x' | Set-Content (Join-Path $d 'allocated.csv')
            'x' | Set-Content (Join-Path $d 'README.txt')
            { Assert-MastNoNoMachineCertsInAssets -AssetsLicenseDir $d } | Should Not Throw
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'throws when a certificate reappears beside the table' {
        # The ambiguous second home is exactly what put expired certificates on
        # mast06 and mast07: refreshed in the copy nobody ships.
        $d = Join-Path $env:TEMP ("mast-assets-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        try {
            'x' | Set-Content (Join-Path $d 'server-02.lic')
            { Assert-MastNoNoMachineCertsInAssets -AssetsLicenseDir $d } | Should Throw
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'is silent when the directory does not exist' {
        { Assert-MastNoNoMachineCertsInAssets -AssetsLicenseDir (Join-Path $env:TEMP 'no-such-dir-here') } | Should Not Throw
    }
}

Describe 'the real assets directory' {

    It 'holds no certificates' {
        $d = Join-Path $here '..\providers\nomachine\assets\licenses'
        { Assert-MastNoNoMachineCertsInAssets -AssetsLicenseDir $d } | Should Not Throw
    }
}


Describe 'Format-MastNoMachineStoreSummary' {

    function Row {
        param($Name, $Expiry, $State, $Days, $HostName = '(unallocated)')
        [pscustomobject]@{ Name = $Name; Subscription = 'LI0X'; RawExpiry = $Expiry; State = $State; DaysLeft = $Days; Host = $HostName }
    }

    It 'collapses seats sharing one expiry into a single line' {
        # Every seat the fleet owns expires on the same day. Ten identical
        # warnings is the worst way to say one renewal is due.
        $rows = 1..10 | ForEach-Object { Row "server-$_.lic" 'Thu Jul 01 15:47:19 CEST 2027' 'expiring' 47 "mast0$_" }
        $r = Format-MastNoMachineStoreSummary -Report $rows
        @($r.Lines).Count | Should Be 1
        $r.Lines[0] | Should Match '^10 seat\(s\) expire'
        $r.Worst | Should Be 'expiring'
    }

    It 'keeps distinct expiry dates on separate lines' {
        $rows = @(
            (Row 'server-01.lic' 'Thu Jul 01 15:47:19 CEST 2027' 'ok' 310),
            (Row 'server-02.lic' 'Wed Oct 01 12:00:00 CEST 2026' 'expiring' 37)
        )
        @((Format-MastNoMachineStoreSummary -Report $rows).Lines).Count | Should Be 2
    }

    It 'sorts the most urgent group first' {
        $rows = @(
            (Row 'server-01.lic' 'Thu Jul 01 15:47:19 CEST 2027' 'ok' 310),
            (Row 'server-02.lic' 'Wed Oct 01 12:00:00 CEST 2026' 'expiring' 37)
        )
        (Format-MastNoMachineStoreSummary -Report $rows).Lines[0] | Should Match 'expire'
    }

    It 'reports the worst state across the whole store' {
        $rows = @(
            (Row 'server-01.lic' 'Thu Jul 01 15:47:19 CEST 2027' 'ok' 310),
            (Row 'server-02.lic' 'Wed Jul 01 14:35:25 CEST 2026' 'expired' -55)
        )
        (Format-MastNoMachineStoreSummary -Report $rows).Worst | Should Be 'expired'
    }

    It 'names the hosts affected, so the line is actionable' {
        $rows = @((Row 'server-05.lic' 'Wed Oct 01 12:00:00 CEST 2026' 'expiring' 37 'mast-ns-spec'))
        (Format-MastNoMachineStoreSummary -Report $rows).Lines[0] | Should Match 'mast-ns-spec'
    }

    It 'says so plainly when the store is empty' {
        (Format-MastNoMachineStoreSummary -Report @()).Worst | Should Be 'none'
    }
}

Describe 'Get-MastNoMachineStoreReport' {

    function New-Store {
        param([hashtable]$Files)
        $d = Join-Path $env:TEMP ("mast-store-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        foreach ($n in $Files.Keys) {
            @('----- Begin subscription data -----', "Subscription Id:       LI-$n", "Expiry:                $($Files[$n])") |
                Set-Content -LiteralPath (Join-Path $d $n) -Encoding ASCII
        }
        return $d
    }

    It 'covers a seat whose host no build ever runs for' {
        # mast-ns-spec holds server-05.lic and is not in unit-registry.json, so
        # the per-staged-certificate check never sees it. This is why the scan
        # reads the store rather than the payload.
        $d = New-Store @{ 'server-05.lic' = 'Wed Oct 01 12:00:00 CEST 2026' }
        try {
            $rep = Get-MastNoMachineStoreReport -StoreDir $d -AllocationByLicense @{ 'server-05.lic' = 'mast-ns-spec' } -Now ([datetime]'2026-08-25')
            @($rep).Count | Should Be 1
            $rep[0].Host | Should Be 'mast-ns-spec'
            $rep[0].State | Should Be 'expiring'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'marks an unclaimed spare as unallocated rather than dropping it' {
        $d = New-Store @{ 'server-09.lic' = 'Thu Jul 01 15:47:19 CEST 2027' }
        try {
            (Get-MastNoMachineStoreReport -StoreDir $d -Now ([datetime]'2026-08-25'))[0].Host | Should Be '(unallocated)'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns nothing for a store that is not there' {
        @(Get-MastNoMachineStoreReport -StoreDir (Join-Path $env:TEMP 'no-store-here')).Count | Should Be 0
    }
}

Describe 'Show-MastNoMachineStoreSummary' {

    It 'never throws, whatever the store looks like' {
        # It runs on every build. A store it cannot read must not stop one.
        { Show-MastNoMachineStoreSummary -StoreDir (Join-Path $env:TEMP 'definitely-not-here') } | Should Not Throw
    }

    It 'reports an absent store as absent, not as an internal error' {
        # 'Should Not Throw' alone passed while the function was quietly falling
        # into its own catch: an empty array returned from a function arrives as
        # $null. Assert the verdict, not merely the absence of an exception.
        $r = Show-MastNoMachineStoreSummary -StoreDir (Join-Path $env:TEMP 'definitely-not-here')
        $r | Should Not BeNullOrEmpty
        $r.Worst | Should Be 'none'
    }
}
