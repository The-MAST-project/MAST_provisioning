# Pester unit tests for the pure resolution logic in server/lib/mast-timezone.ps1.
#
# Mirrors the mast-pull-staging tests: dot-source the lib (no I/O, no unit) and
# assert the DECISIONS -- that IANA ids resolve, raw Windows ids pass through,
# and an unknown id throws rather than silently falling back.
#
# Run (Pester 3.x, shipped with Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\mast-timezone.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\lib\mast-timezone.ps1')

Describe 'Resolve-TimeZoneInfo' {
    It 'resolves the IANA id stored in unit-registry.json (Asia/Jerusalem)' {
        $z = Resolve-TimeZoneInfo -Id 'Asia/Jerusalem'
        $z | Should Not BeNullOrEmpty
        # Israel standard offset is UTC+2 (DST +3); BaseUtcOffset is the
        # standard offset. Asserts a real zone came back, not a swallowed throw.
        $z.BaseUtcOffset.TotalHours | Should Be 2
    }
    It 'passes a raw Windows id straight through' {
        (Resolve-TimeZoneInfo -Id 'Israel Standard Time').BaseUtcOffset.TotalHours | Should Be 2
    }
    It 'resolves UTC' {
        (Resolve-TimeZoneInfo -Id 'UTC').BaseUtcOffset.TotalHours | Should Be 0
    }
    It 'throws on an id that is neither a Windows id nor a mapped IANA id' {
        { Resolve-TimeZoneInfo -Id 'Nowhere/Notreal' } | Should Throw
    }
}
