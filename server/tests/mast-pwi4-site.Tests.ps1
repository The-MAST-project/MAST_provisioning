# Pester unit tests for server/lib/mast-pwi4-site.ps1 (MAST_provisioning#209).
#
# The site values are the ones the fleet carried on 2026-10-06: the ns.toml site, the
# value PWI4 re-rounds it to when it rewrites PWI4.cfg, and the rounded 30.053 /
# 35.0408055555556 found on mast03, mast04 and mast05.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\mast-pwi4-site.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\lib\mast-pwi4-site.ps1')

$nsToml = Join-Path $here '..\providers\config-bootstrap\sites\ns.toml'

function New-Cfg {
    param([string]$Path, [string]$Latitude, [string]$Longitude, [string]$Height = '400')
    Set-Content -LiteralPath $Path -Encoding ASCII -Value @(
        'SerialPort          = COM7',
        ('Latitude            = {0}' -f $Latitude),
        ('Longitude           = {0}' -f $Longitude),
        ('HeightMeters        = {0}' -f $Height),
        'ConnectionMethod    = usb'
    )
}

function New-Pxp {
    param([string]$Path, [string]$Latitude, [string]$Longitude)
    Set-Content -LiteralPath $Path -Encoding ASCII -Value @(
        'Number of Cal Stars:', '1', '', 'Cal Star 1:', '', 'RA, Dec:', '4.75', '0.30',
        'Latitude, Longitude, TimeZone, DST:', $Latitude, $Longitude, '2', 'True'
    )
}

Describe 'Get-MastTomlLocation' {
    It 'reads the ns site profile as text and as numbers' {
        $loc = Get-MastTomlLocation -Path $nsToml
        $loc.LatitudeText | Should Be '30.05301166519461'
        $loc.LongitudeText | Should Be '35.04079611164462'
        $loc.Latitude | Should Be 30.05301166519461
        $loc.Height | Should Be 400
    }
    It 'refuses a profile with no longitude' {
        $p = Join-Path $TestDrive 'nolon.toml'
        Set-Content -LiteralPath $p -Value @('[location]', 'latitude = 30.0', 'elevation = 400')
        { Get-MastTomlLocation -Path $p } | Should Throw
    }
}

Describe 'Get-MastPwi4CfgSite' {
    It 'reads the three site fields from an aligned cfg' {
        $p = Join-Path $TestDrive 'PWI4.cfg'
        New-Cfg -Path $p -Latitude '30.0530116651946' -Longitude '35.0407961116446'
        $site = Get-MastPwi4CfgSite -Path $p
        $site.Latitude | Should Be 30.0530116651946
        $site.Longitude | Should Be 35.0407961116446
        $site.Height | Should Be 400
    }
    It 'refuses a cfg with no HeightMeters' {
        $p = Join-Path $TestDrive 'noheight.cfg'
        Set-Content -LiteralPath $p -Value @('Latitude = 30.0', 'Longitude = 35.0')
        { Get-MastPwi4CfgSite -Path $p } | Should Throw
    }
}

Describe 'Get-MastPxpSite' {
    It 'reads the site a model was built at' {
        $p = Join-Path $TestDrive 'model.pxp'
        New-Pxp -Path $p -Latitude '30.053' -Longitude '35.0408055555556'
        $site = Get-MastPxpSite -Path $p
        $site.Latitude | Should Be 30.053
        $site.Longitude | Should Be 35.0408055555556
    }
    It 'returns null for a file with no site block' {
        $p = Join-Path $TestDrive 'nosite.pxp'
        Set-Content -LiteralPath $p -Value @('Number of Cal Stars:', '0')
        Get-MastPxpSite -Path $p | Should Be $null
    }
}

Describe 'Test-MastSiteMatch' {
    $ns = Get-MastTomlLocation -Path $nsToml
    It 'matches the value PWI4 re-rounds the ns site to' {
        $rewritten = [pscustomobject]@{ Latitude = 30.0530116651946; Longitude = 35.0407961116446; Height = 400.0 }
        Test-MastSiteMatch -A $rewritten -B $ns | Should Be $true
    }
    It 'does not match the rounded site on mast03, mast04 and mast05' {
        $rounded = [pscustomobject]@{ Latitude = 30.053; Longitude = 35.0408055555556; Height = 400.0 }
        Test-MastSiteMatch -A $rounded -B $ns | Should Be $false
    }
    It 'does not match a different height' {
        $higher = [pscustomobject]@{ Latitude = $ns.Latitude; Longitude = $ns.Longitude; Height = 410.0 }
        Test-MastSiteMatch -A $higher -B $ns | Should Be $false
    }
    It 'compares a model, which records no height, on latitude and longitude only' {
        $model = [pscustomobject]@{ Latitude = $ns.Latitude; Longitude = $ns.Longitude }
        Test-MastSiteMatch -A $model -B $ns | Should Be $true
    }
}

Describe 'Set-MastPwi4CfgField' {
    It 'replaces the value, keeps the padding, and leaves other fields alone' {
        $p = Join-Path $TestDrive 'set.cfg'
        New-Cfg -Path $p -Latitude '30.053' -Longitude '35.0408055555556'
        Set-MastPwi4CfgField -Path $p -Field 'Longitude' -Value '35.04079611164462'
        $lines = @(Get-Content -LiteralPath $p)
        $lines[2] | Should Be 'Longitude           = 35.04079611164462'
        $lines[0] | Should Be 'SerialPort          = COM7'
        $lines[1] | Should Be 'Latitude            = 30.053'
    }
    It 'appends a field the cfg does not have' {
        $p = Join-Path $TestDrive 'append.cfg'
        Set-Content -LiteralPath $p -Value @('Latitude = 30.0', 'Longitude = 35.0')
        Set-MastPwi4CfgField -Path $p -Field 'HeightMeters' -Value '400'
        @(Get-Content -LiteralPath $p)[-1] | Should Be 'HeightMeters = 400'
    }
}

# --- the provider and its verify, end to end, against planted files ------------------------

$provide = Join-Path $here '..\providers\pwi4-site\provide-pwi4-site.ps1'
$verify = Join-Path $here '..\providers\pwi4-site\verify-pwi4-site.ps1'

function Invoke-Script {
    param([string]$Path, [string[]]$Arguments)
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

function New-Unit {
    # A settings dir holding a PWI4.cfg at the rounded mast03/04/05 site, and a model built there.
    param([string]$Name, [switch]$NoCfg, [switch]$NoModel)
    $root = Join-Path $TestDrive $Name
    $settings = Join-Path $root 'Settings'
    New-Item -ItemType Directory -Path $settings -Force | Out-Null
    if (-not $NoCfg) { New-Cfg -Path (Join-Path $settings 'PWI4.cfg') -Latitude '30.053' -Longitude '35.0408055555556' }
    $model = Join-Path $root 'DefaultModel.pxp'
    if (-not $NoModel) { New-Pxp -Path $model -Latitude '30.053' -Longitude '35.0408055555556' }
    return [pscustomobject]@{ Settings = $settings; Model = $model; Cfg = (Join-Path $settings 'PWI4.cfg') }
}

function Get-Args {
    param($Unit, [string]$Process = 'MastNoSuchProcess')
    return @('-UnitToml', $nsToml, '-Pwi4SettingsDir', $Unit.Settings, '-ModelPath', $Unit.Model, '-Pwi4ProcessName', $Process)
}

Describe 'provide-pwi4-site.ps1' {
    $env:MAST_LOG_SESSION_DIR = Join-Path $TestDrive 'logs'

    It 'writes the configured site, keeps the other fields, backs up, and warns about the orphaned model' {
        $u = New-Unit -Name 'drifted'
        $r = Invoke-Script -Path $provide -Arguments (Get-Args $u)
        $r.ExitCode | Should Be 0
        $site = Get-MastPwi4CfgSite -Path $u.Cfg
        Test-MastSiteMatch -A $site -B (Get-MastTomlLocation -Path $nsToml) | Should Be $true
        (Get-Content -LiteralPath $u.Cfg)[0] | Should Be 'SerialPort          = COM7'
        @(Get-ChildItem -Path $u.Settings -Filter 'PWI4.cfg.*.bak').Count | Should Be 1
        $r.Output | Should Match 'POINTING MODEL ORPHANED'
    }

    It 'writes nothing on a second run' {
        $u = New-Unit -Name 'twice'
        Invoke-Script -Path $provide -Arguments (Get-Args $u) | Out-Null
        $before = (Get-Item -LiteralPath $u.Cfg).LastWriteTimeUtc
        $r = Invoke-Script -Path $provide -Arguments (Get-Args $u)
        $r.ExitCode | Should Be 0
        $r.Output | Should Match 'nothing written'
        (Get-Item -LiteralPath $u.Cfg).LastWriteTimeUtc | Should Be $before
        @(Get-ChildItem -Path $u.Settings -Filter 'PWI4.cfg.*.bak').Count | Should Be 1
    }

    It 'refuses while PWI4 runs and leaves the cfg untouched' {
        $u = New-Unit -Name 'running'
        $r = Invoke-Script -Path $provide -Arguments (Get-Args $u -Process 'powershell')
        $r.ExitCode | Should Be 1
        $r.Output | Should Match 'is running'
        (Get-MastPwi4CfgSite -Path $u.Cfg).Latitude | Should Be 30.053
    }

    It 'has nothing to align before the profiles are applied' {
        $u = New-Unit -Name 'fresh' -NoCfg -NoModel
        $r = Invoke-Script -Path $provide -Arguments (Get-Args $u)
        $r.ExitCode | Should Be 0
        Test-Path -LiteralPath $u.Cfg | Should Be $false
    }
}

Describe 'verify-pwi4-site.ps1' {
    It 'fails a drifted cfg' {
        $u = New-Unit -Name 'vdrift'
        (Invoke-Script -Path $verify -Arguments @('-UnitToml', $nsToml, '-Pwi4SettingsDir', $u.Settings, '-ModelPath', $u.Model)).ExitCode | Should Be 1
    }
    It 'passes an aligned cfg and still warns about the model' {
        $u = New-Unit -Name 'valigned'
        $env:MAST_LOG_SESSION_DIR = Join-Path $TestDrive 'logs'
        Invoke-Script -Path $provide -Arguments (Get-Args $u) | Out-Null
        $r = Invoke-Script -Path $verify -Arguments @('-UnitToml', $nsToml, '-Pwi4SettingsDir', $u.Settings, '-ModelPath', $u.Model)
        $r.ExitCode | Should Be 0
        $r.Output | Should Match 'WARN'
    }
    It 'cannot verify a unit with no live cfg yet' {
        $u = New-Unit -Name 'vfresh' -NoCfg -NoModel
        (Invoke-Script -Path $verify -Arguments @('-UnitToml', $nsToml, '-Pwi4SettingsDir', $u.Settings, '-ModelPath', $u.Model)).ExitCode | Should Be 2
    }
}
