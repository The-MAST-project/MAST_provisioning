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


# The expiry verdict is shared with the unit side; see server/lib/mast-license.ps1.
${_licDot} = Join-Path ${PSScriptRoot} '..\server\lib\mast-license.ps1'
if (-not (Test-Path ${_licDot})) { throw "mast-license.ps1 not found at ${_licDot}" }
. ${_licDot}

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


function Get-MastLicenseStoreReport {
    <#
    .SYNOPSIS
      Every certificate in the store, with its verdict. Not just the one being staged.
    .DESCRIPTION
      The per-certificate check in Assert-MastLicenseIsShippable only ever sees
      the seat for the host currently being built. Two things fall through that:
      a seat allocated to a host no build runs for -- mast-ns-spec holds one and
      is not in unit-registry.json, so nothing checks it -- and a spare nobody
      has claimed yet.

      This reads the whole store instead, so a build reports on every seat the
      fleet owns regardless of which unit prompted it.
    .PARAMETER AllocationByLicense
      Optional map of licence filename -> host, so the summary can name the
      units affected. Absent, seats are reported by filename alone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StoreDir,
        [hashtable]$AllocationByLicense = @{},
        [datetime]$Now = (Get-Date)
    )

    if (-not (Test-Path -LiteralPath $StoreDir)) { return @() }
    $out = @()
    foreach ($f in (Get-ChildItem -LiteralPath $StoreDir -Filter '*.lic' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $raw = Get-MastLicenseField -Path $f.FullName -Field 'Expiry'
        $v = Test-MastLicenseExpiry -RawExpiry $raw -Now $Now
        $host_ = ''
        if ($AllocationByLicense.ContainsKey($f.Name)) { $host_ = [string]$AllocationByLicense[$f.Name] }
        $out += [pscustomobject]@{
            Name         = $f.Name
            Subscription = Get-MastLicenseField -Path $f.FullName -Field 'Subscription Id'
            RawExpiry    = $raw
            State        = $v.State
            DaysLeft     = $v.DaysLeft
            Host         = $(if ($host_) { $host_ } else { '(unallocated)' })
        }
    }
    return $out
}

function Format-MastLicenseStoreSummary {
    <#
    .SYNOPSIS
      Collapse a store report into the fewest lines that say what is owed.
    .DESCRIPTION
      GROUPED BY EXPIRY DATE, not by seat. Every certificate the fleet owns
      expires on the same day (2027-07-01), so a per-seat rendering would print
      ten identical warnings in every build once the window opens -- which is the
      worst possible presentation of "one renewal is due". Output should scale
      with the number of RENEWALS, not the number of units.

      Pure: takes the report and returns lines plus the worst state seen, so the
      grouping can be tested without a store or a clock.
    #>
    [CmdletBinding()]
    param([AllowNull()][Parameter(Mandatory)]$Report)

    $rows = @($Report)
    if ($rows.Count -eq 0) {
        return [pscustomobject]@{ Worst = 'none'; Lines = @('certificate store: empty or absent') }
    }

    $rank = @{ 'ok' = 0; 'unknown' = 1; 'expiring' = 2; 'expired' = 3 }
    $worst = 'ok'
    foreach ($r in $rows) { if ($rank[[string]$r.State] -gt $rank[$worst]) { $worst = [string]$r.State } }

    $lines = @()
    foreach ($g in ($rows | Group-Object RawExpiry | Sort-Object { @($_.Group)[0].DaysLeft })) {
        $first = @($g.Group)[0]
        $hosts = (@($g.Group) | ForEach-Object { $_.Host } | Sort-Object) -join ', '
        $when = $(if ($first.RawExpiry) { $first.RawExpiry } else { 'an unreadable date' })
        switch ([string]$first.State) {
            'expired'  { $lines += ("{0} seat(s) EXPIRED on {1} ({2} day(s) ago): {3}" -f $g.Count, $when, [math]::Abs($first.DaysLeft), $hosts) }
            'expiring' { $lines += ("{0} seat(s) expire {1} -- {2} day(s) left: {3}" -f $g.Count, $when, $first.DaysLeft, $hosts) }
            'unknown'  { $lines += ("{0} seat(s) have an unreadable expiry ({1}): {2}" -f $g.Count, $when, $hosts) }
            default    { $lines += ("{0} seat(s) valid until {1} ({2} day(s))" -f $g.Count, $when, $first.DaysLeft) }
        }
    }
    return [pscustomobject]@{ Worst = $worst; Lines = $lines }
}

function Show-MastLicenseStoreSummary {
    <#
    .SYNOPSIS
      Report on every seat the fleet owns, once per build. Never throws.
    .DESCRIPTION
      Runs on every build, including dev-VM cycles: the cost is reading ten small
      text files, and the alternative is that the one build which would have told
      you is the one nobody ran.

      It NEVER fails the build, at any proximity. Renewal is a purchase with
      institutional lead time; a build that refuses to run because a certificate
      expires in three weeks would block unit work for a reason nobody on the run
      can fix. The hard stop is Assert-MastLicenseIsShippable, and it fires only
      on a certificate that has already expired -- where the unit would lose
      NoMachine outright.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StoreDir,
        [hashtable]$AllocationByLicense = @{},
        [datetime]$Now = (Get-Date)
    )

    try {
        # @() at the call site: an empty array returned from a function arrives
        # here as $null, which the summary would otherwise refuse to bind.
        $report = @(Get-MastLicenseStoreReport -StoreDir $StoreDir -AllocationByLicense $AllocationByLicense -Now $Now)
        $summary = Format-MastLicenseStoreSummary -Report $report
        $urgent = @($report | Where-Object { $_.State -eq 'expiring' -and $_.DaysLeft -le $script:MastLicenseUrgentDays }).Count -gt 0

        if ($summary.Worst -eq 'ok') {
            foreach ($l in $summary.Lines) { Write-Host ("[build-mast] {0}" -f $l) }
            return $summary
        }

        Write-Host '==================================================================='
        Write-Host ('[build-mast] *** NoMachine seats need attention ***' + $(if ($urgent) { ' -- URGENT' } else { '' }))
        foreach ($l in $summary.Lines) { Write-Warning ("[build-mast] {0}" -f $l) }
        if ($summary.Worst -eq 'expiring') {
            Write-Warning '[build-mast] Renewal is a purchase with lead time -- start it now; the build will not do it for you.'
        }
        if ($summary.Worst -eq 'expired') {
            Write-Warning '[build-mast] An expired seat cannot be shipped: the build refuses the host it belongs to.'
        }
        Write-Host '==================================================================='
        return $summary
    }
    catch {
        # A store that cannot be read must not stop a build; say so and continue.
        Write-Warning ("[build-mast] certificate store could not be summarised: {0}" -f $_.Exception.Message)
        return $null
    }
}
