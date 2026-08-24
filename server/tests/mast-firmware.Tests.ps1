# Unit tests for server\lib\mast-firmware.ps1 -- the BIOS power-policy check.
#
# Test-MastFirmwarePolicy is deliberately pure (it takes a setup blob and a
# baseline and returns a verdict), so the interesting cases can be exercised
# without firmware: the hardware-touching half is Get-MastFirmwareSetup, which
# these tests do not call.
#
# The case that matters most here is the LENGTH MISMATCH one. It is easy to
# write this check so that a varstore it cannot actually read comes back clean,
# and a quiet pass is worse than no check at all -- the whole point is to notice
# a unit that will not power itself back on after a mains event.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\mast-firmware.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\lib\mast-firmware.ps1')

function New-TestSetup {
    param(
        [int]$Length = 3399,
        [hashtable]$Bytes = @{},
        [string]$Sha256 = 'aa',
        [bool]$Available = $true,
        [string]$Reason = ''
    )
    $buf = New-Object byte[] $Length
    foreach ($k in $Bytes.Keys) { $buf[[int]$k] = [byte]$Bytes[$k] }
    return [pscustomobject]@{
        Available        = $Available
        Reason           = $Reason
        Bytes            = $buf
        Sha256           = $Sha256
        Length           = $Length
        BaseboardProduct = 'PE2100U-C7136ES'
        BiosVersion      = '1.03.00'
    }
}

function New-TestBaseline {
    param([int]$SetupLength = 3399, [string]$Sha256 = 'aa')
    return [pscustomobject]@{
        baseboard_product = 'PE2100U-C7136ES'
        bios_version      = '1.03.00'
        setup_length      = $SetupLength
        setup_sha256      = $Sha256
        fields            = @(
            [pscustomobject]@{ name = 'Restore AC Power Loss'; offset = 3378; expect = 1; meaning = '1 = S0 State'; remedy = 'APM Configuration' },
            [pscustomobject]@{ name = 'Power On By PCIE/PCI'; offset = 3380; expect = 0; meaning = '0 = Disabled' }
        )
    }
}

Describe 'Test-MastFirmwarePolicy' {

    It 'reports match when the hash and every named field agree' {
        $r = Test-MastFirmwarePolicy -Setup (New-TestSetup -Bytes @{ 3378 = 1; 3380 = 0 }) -Baseline (New-TestBaseline)
        $r.Status | Should Be 'match'
        $r.NeedsAttention | Should Be $false
        $r.BaselineMatched | Should Be $true
    }

    It 'reports field-drift and needs attention when the power-on setting is wrong' {
        $r = Test-MastFirmwarePolicy -Setup (New-TestSetup -Bytes @{ 3378 = 0; 3380 = 0 } -Sha256 'bb') -Baseline (New-TestBaseline)
        $r.Status | Should Be 'field-drift'
        $r.NeedsAttention | Should Be $true
        ($r.Messages -join ' ') | Should Match 'Restore AC Power Loss'
    }

    It 'carries the remedy line for a drifted field so the operator knows where to go' {
        $r = Test-MastFirmwarePolicy -Setup (New-TestSetup -Bytes @{ 3378 = 0 } -Sha256 'bb') -Baseline (New-TestBaseline)
        ($r.Messages -join ' ') | Should Match 'APM Configuration'
    }

    It 'reports blob-drift WITHOUT demanding attention when only unknown bytes moved' {
        # Something else in BIOS setup changed. Worth saying; not worth a
        # keystroke, or operators learn to dismiss the keystroke.
        $r = Test-MastFirmwarePolicy -Setup (New-TestSetup -Bytes @{ 3378 = 1; 3380 = 0 } -Sha256 'zz') -Baseline (New-TestBaseline)
        $r.Status | Should Be 'blob-drift'
        $r.NeedsAttention | Should Be $false
    }

    It 'reports unknown-baseline when no entry describes this board' {
        $r = Test-MastFirmwarePolicy -Setup (New-TestSetup) -Baseline $null
        $r.Status | Should Be 'unknown-baseline'
        $r.NeedsAttention | Should Be $true
    }

    It 'does NOT pass a varstore whose length the baseline does not describe' {
        # Regression guard: an earlier cut compared field offsets against a
        # differently-sized struct, found them "correct", and returned a clean
        # verdict on firmware it had never actually read.
        $r = Test-MastFirmwarePolicy -Setup (New-TestSetup -Length 64) -Baseline (New-TestBaseline)
        $r.Status | Should Be 'unknown-baseline'
        $r.NeedsAttention | Should Be $true
        ($r.Messages -join ' ') | Should Match 'NOT verified'
    }

    It 'does not claim a clean bill when every declared field was unreadable' {
        $b = New-TestBaseline
        $b.fields = @([pscustomobject]@{ name = 'Way Off'; offset = 99999; expect = 1; meaning = 'x' })
        $r = Test-MastFirmwarePolicy -Setup (New-TestSetup) -Baseline $b
        $r.Status | Should Be 'unknown-baseline'
        $r.NeedsAttention | Should Be $true
    }

    It 'reports unavailable, and does not demand attention, when firmware cannot be read' {
        # The dev VM and any legacy-BIOS box land here. Asking for an
        # acknowledgment nobody can give would hang every VM bootstrap cycle.
        $r = Test-MastFirmwarePolicy -Setup (New-TestSetup -Available $false -Reason 'win32 error 203') -Baseline (New-TestBaseline)
        $r.Status | Should Be 'unavailable'
        $r.NeedsAttention | Should Be $false
    }

    It 'passes the board and BIOS identity through for the caller to record' {
        $r = Test-MastFirmwarePolicy -Setup (New-TestSetup -Bytes @{ 3378 = 1; 3380 = 0 }) -Baseline (New-TestBaseline)
        $r.BaseboardProduct | Should Be 'PE2100U-C7136ES'
        $r.BiosVersion | Should Be '1.03.00'
    }
}

Describe 'firmware-baseline.json' {

    It 'is valid JSON and every field entry is complete' {
        $path = Join-Path $here '..\data\firmware-baseline.json'
        Test-Path -LiteralPath $path | Should Be $true
        $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        @($doc.boards).Count -gt 0 | Should Be $true
        foreach ($b in @($doc.boards)) {
            [string]::IsNullOrWhiteSpace($b.baseboard_product) | Should Be $false
            [string]::IsNullOrWhiteSpace($b.bios_version) | Should Be $false
            [string]::IsNullOrWhiteSpace($b.setup_sha256) | Should Be $false
            ([int]$b.setup_length -gt 0) | Should Be $true
            foreach ($f in @($b.fields)) {
                [string]::IsNullOrWhiteSpace($f.name) | Should Be $false
                ([int]$f.offset -lt [int]$b.setup_length) | Should Be $true
            }
        }
    }

    It 'records bytes whose hash matches the recorded sha256' {
        # The two are written together; if they ever disagree, a real drift
        # would be reported with a nonsense byte count.
        $path = Join-Path $here '..\data\firmware-baseline.json'
        $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        foreach ($b in @($doc.boards)) {
            if (-not $b.setup_base64) { continue }
            $bytes = [Convert]::FromBase64String([string]$b.setup_base64)
            $bytes.Length | Should Be ([int]$b.setup_length)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
            (($hash | ForEach-Object { $_.ToString('x2') }) -join '') | Should Be ([string]$b.setup_sha256)
        }
    }
}
