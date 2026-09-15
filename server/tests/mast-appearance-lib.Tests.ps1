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

Describe 'Update-MastStaleBackground' {
    # What makes the date on the wall true. The desktop-appearance provider renders
    # from inside the command loop, where installed-manifest.json still holds the
    # PREVIOUS run's date, so a single run paints a wall one run behind: mast04 was
    # provisioned 2026-09-14 and stated 2026-09-02. mast07 hid it -- an earlier run
    # that day had written the manifest without rendering, so the next run's render
    # found today's date already there (#207).
    $appearance = Join-Path $root 'desktop'
    New-Item -ItemType Directory -Force -Path $appearance | Out-Null
    Copy-Item -LiteralPath (Join-Path $here '..\..\server\providers\desktop-appearance\render-desktop-background.ps1') `
              -Destination $appearance -Force
    $toml = Join-Path $root 'config.toml'
    Set-Content -LiteralPath $toml -Value "site = `"ns`"" -Encoding Ascii

    function New-Sidecar {
        param([string]$Name, [string]$Provisioned)
        $dir = Join-Path $root $Name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $image = Join-Path $dir 'background.png'
        Set-Content -LiteralPath $image -Value 'placeholder' -Encoding Ascii -NoNewline
        $sidecar = Join-Path $dir 'background.json'
        Set-Content -LiteralPath $sidecar -Encoding Ascii -Value (ConvertTo-Json @{
            image         = $image
            static_fields = @{ provisioned = $Provisioned }
        })
        return [pscustomobject]@{ Sidecar = $sidecar; Image = $image }
    }

    It 'replaces an image that states an older run with a real PNG' {
        $m = New-Manifest -Name 'rerender.json' -Body '{"installed_at":"2026-09-14T11:56:25Z","modules":{}}'
        $s = New-Sidecar -Name 'stale' -Provisioned '2026-09-02'
        Update-MastStaleBackground -SidecarPath $s.Sidecar -AppearanceRoot $appearance `
            -UnitToml $toml -InstalledManifest $m | Should Be $true
        # The file is the assertion, not the return value: the failure this guards
        # against returned from the compare correctly and then wrote nothing.
        $bytes = [System.IO.File]::ReadAllBytes($s.Image)
        $bytes[0] | Should Be 137
        [System.Text.Encoding]::ASCII.GetString($bytes[1..3]) | Should Be 'PNG'
    }

    It 'records the run date in the rewritten sidecar, so the next compare agrees' {
        $m = New-Manifest -Name 'rerender2.json' -Body '{"installed_at":"2026-09-14T11:56:25Z","modules":{}}'
        $s = New-Sidecar -Name 'stale2' -Provisioned '2026-09-02'
        [void](Update-MastStaleBackground -SidecarPath $s.Sidecar -AppearanceRoot $appearance `
            -UnitToml $toml -InstalledManifest $m)
        (Get-Content -LiteralPath $s.Sidecar -Raw | ConvertFrom-Json).static_fields.provisioned |
            Should Be '2026-09-14'
    }

    It 'leaves a current image alone' {
        $m = New-Manifest -Name 'current.json' -Body '{"installed_at":"2026-09-14T11:56:25Z","modules":{}}'
        $s = New-Sidecar -Name 'fresh' -Provisioned '2026-09-14'
        Update-MastStaleBackground -SidecarPath $s.Sidecar -AppearanceRoot $appearance `
            -UnitToml $toml -InstalledManifest $m | Should Be $false
        Get-Content -LiteralPath $s.Image -Raw | Should Be 'placeholder'
    }

    It 'reads the manifest given to it, which is what the ordering fix depends on' {
        # The defect was WHEN this ran, not what it computed: called before the
        # manifest is merged it sees the prior run and agrees with a stale image.
        # Both manifests below are legitimate inputs; only the caller's position in
        # the run decides which one is on disk.
        $before = New-Manifest -Name 'before-run.json' -Body '{"installed_at":"2026-09-02T19:26:40Z","modules":{}}'
        $after  = New-Manifest -Name 'after-run.json'  -Body '{"installed_at":"2026-09-14T11:56:25Z","modules":{}}'
        $s = New-Sidecar -Name 'ordering' -Provisioned '2026-09-02'
        Update-MastStaleBackground -SidecarPath $s.Sidecar -AppearanceRoot $appearance `
            -UnitToml $toml -InstalledManifest $before | Should Be $false
        Update-MastStaleBackground -SidecarPath $s.Sidecar -AppearanceRoot $appearance `
            -UnitToml $toml -InstalledManifest $after | Should Be $true
    }
}

Describe 'Set-MastLiveDesktop' {
    # The interop half -- SystemParametersInfo and the ImmersiveColorSet broadcast --
    # is not exercised here. It only does anything inside a logon session with a
    # desktop, and a test that made it succeed would repaint the machine running the
    # suite. What IS tested is the guard that decides whether to touch HKCU at all,
    # because that is the half that can be silently wrong.

    It 'refuses to write a hive belonging to another account' {
        # It asserts the theme into the CALLING process's HKCU. Execute runs as mast
        # under the detached task, but the WinRM fallback path does not -- and writing
        # mast's wallpaper into an administrator's hive would succeed and be wrong.
        $r = Set-MastLiveDesktop -ImagePath 'C:\nonexistent\background.png' -MastUser 'not-the-logged-on-user'
        $r.Applied | Should Be $false
        $r.Detail  | Should Match 'not-the-logged-on-user'
    }

    It 'fails loudly when it is the right user and the image is gone' {
        { Set-MastLiveDesktop -ImagePath (Join-Path $root 'no-such-image.png') -MastUser $env:USERNAME } |
            Should Throw
    }
}
