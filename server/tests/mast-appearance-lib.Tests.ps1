# Unit tests for the provisioning date the desktop background states (#200).
#
# The renderer used to print Get-Date under the label "provisioned", so the image
# stated the date it was MADE as the date the unit was PROVISIONED. mast07 showed
# "provisioned 2026-09-02" after being provisioned on 2026-09-14. The value now
# comes from the unit's own installed-manifest.json, and the rule these tests hold
# is that it is either that date or the word 'unknown' -- never a guess, never a
# blank that reads as recent, never an unparsed string echoed onto a wall.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\mast-appearance-lib.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\..\server\providers\desktop-appearance\mast-appearance-lib.ps1')

$root = Join-Path $env:TEMP ("mast-appearance-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$root = (Get-Item -LiteralPath $root).FullName

function New-Manifest {
    param([string]$Name, [string]$Body)
    $p = Join-Path $root $Name
    Set-Content -LiteralPath $p -Value $Body -Encoding Ascii
    return $p
}

Describe 'Get-MastProvisionedDate' {
    It 'reports the date the unit records, not the clock' {
        $m = New-Manifest -Name 'good.json' -Body '{"installed_at":"2026-09-14T11:56:25Z","modules":{}}'
        Get-MastProvisionedDate -InstalledManifest $m | Should Be '2026-09-14'
    }
    It 'says unknown when the unit has never completed a run' {
        Get-MastProvisionedDate -InstalledManifest (Join-Path $root 'absent.json') | Should Be 'unknown'
    }
    It 'says unknown rather than guessing when the manifest is corrupt' {
        $m = New-Manifest -Name 'corrupt.json' -Body '{ this is not json'
        Get-MastProvisionedDate -InstalledManifest $m | Should Be 'unknown'
    }
    It 'says unknown when installed_at is absent or empty' {
        $a = New-Manifest -Name 'noattr.json' -Body '{"modules":{}}'
        $b = New-Manifest -Name 'empty.json'  -Body '{"installed_at":"","modules":{}}'
        Get-MastProvisionedDate -InstalledManifest $a | Should Be 'unknown'
        Get-MastProvisionedDate -InstalledManifest $b | Should Be 'unknown'
    }
    It 'does not echo an unparsable value onto the wallpaper' {
        # Whatever is in the field, what reaches the image is a date or 'unknown'.
        $m = New-Manifest -Name 'junk.json' -Body '{"installed_at":"yesterday-ish","modules":{}}'
        Get-MastProvisionedDate -InstalledManifest $m | Should Be 'unknown'
    }
    It 'never returns an empty string, which would read as a missing label' {
        foreach ($n in 'good.json', 'corrupt.json', 'noattr.json', 'junk.json') {
            (Get-MastProvisionedDate -InstalledManifest (Join-Path $root $n)) | Should Not BeNullOrEmpty
        }
    }
}

Describe 'Get-MastAppearanceFields provisioned field' {
    It 'carries the date so verify compares it like any other static field' {
        # This is what turns a stale wallpaper into a tier-2 needs-repair instead
        # of a false statement nobody notices.
        $m = New-Manifest -Name 'fields.json' -Body '{"installed_at":"2026-09-14T11:56:25Z","modules":{}}'
        $f = Get-MastAppearanceFields -UnitToml (Join-Path $root 'no-such.toml') -InstalledManifest $m
        $f.provisioned | Should Be '2026-09-14'
        $f.Keys -contains 'provisioned' | Should Be $true
    }
}
