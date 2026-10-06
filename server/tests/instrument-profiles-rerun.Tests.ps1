# Pester tests: re-running instrument-profiles on a deployed unit leaves its live profiles
# alone (MAST_provisioning#209 rollout, #190).
#
# Until this change, provide deleted the staging dir with its '.applied' sentinel and
# registered the apply task again, and apply then copied every template .cfg over the live
# ones and re-imported the PHD2 profiles at the next logon -- resetting calibrated COM
# bindings and PHD2 tuning on every unit a provisioning run touched.
#
# The scripts run end to end as child processes against planted files. The PHD2 import
# goes to a throwaway HKCU:\Software\MAST-Tests-<guid> key, removed at the end, so no real
# PHD2 settings are touched.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\instrument-profiles-rerun.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$providerDir = Join-Path $here '..\providers\instrument-profiles'
$provide = Join-Path $providerDir 'provide-instrument-profiles.ps1'
$apply = Join-Path $providerDir 'apply-instrument-profiles.ps1'
$verify = Join-Path $providerDir 'verify-instrument-profiles.ps1'
$nsToml = Join-Path $here '..\providers\config-bootstrap\sites\ns.toml'
$noTask = 'MAST-Tests-NoSuchTask'

function Invoke-Script {
    param([string]$Path, [string[]]$Arguments)
    # A child's stderr arrives as error records through 2>&1 (reg.exe reports success on
    # stderr); do not let a 'Stop' left by another suite turn that into a throw here.
    $ErrorActionPreference = 'Continue'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    return [pscustomobject]@{ ExitCode = $code; Output = $out }
}

function New-Bundle {
    # A stand-in for assets\instrument-profiles-assets.zip, which is in Git LFS and is
    # only a pointer file in CI's checkout. Same layout: the ten cfgs verify expects,
    # and the PHD2 .reg.
    param([string]$Name)
    $src = Join-Path $TestDrive "$Name-src"
    $settings = Join-Path $src 'PWI4\Settings'
    New-Item -ItemType Directory -Path $settings -Force | Out-Null
    foreach ($cfg in 'ASCOM.Camera_1.cfg', 'EFA.Controller_1.cfg', 'EFA.Hedrick.Focuser_1.cfg',
        'Elmo.Controller.cfg', 'Elmo.L500.Mount.cfg', 'GUI.cfg',
        'PWBus.StandardOTA.Controller.cfg', 'TempManager.cfg', 'Telemetry.cfg') {
        Set-Content -LiteralPath (Join-Path $settings $cfg) -Encoding ASCII -Value 'Key = (template)'
    }
    Set-Content -LiteralPath (Join-Path $settings 'PWI4.cfg') -Encoding ASCII -Value @(
        'Latitude            = 0', 'Longitude           = 0', 'HeightMeters        = 0')
    Set-Content -LiteralPath (Join-Path $src 'phd2_profiles.reg') -Encoding Unicode -Value 'Windows Registry Editor Version 5.00'
    $assetsDir = Join-Path $TestDrive "$Name-assets"
    New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null
    Compress-Archive -Path (Join-Path $src '*') -DestinationPath (Join-Path $assetsDir 'instrument-profiles-assets.zip')
    return $assetsDir
}

function Get-Sha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

Describe 'provide-instrument-profiles.ps1 on a re-run' {
    $env:MAST_LOG_SESSION_DIR = Join-Path $TestDrive 'logs'
    $root = Join-Path $TestDrive 'staging'
    $provideArgs = @('-AssetsRoot', (New-Bundle -Name 'rerun'), '-ProfilesRoot', $root, '-UnitToml', $nsToml, '-SkipTask')

    It 'stages the templates on a first run' {
        (Invoke-Script -Path $provide -Arguments $provideArgs).ExitCode | Should Be 0
        Test-Path -LiteralPath (Join-Path $root 'PWI4\Settings\PWI4.cfg') | Should Be $true
    }

    It 'keeps the applied sentinel and does not re-arm the apply task' {
        Set-Content -LiteralPath (Join-Path $root '.applied') -Value 'applied by a test'
        $r = Invoke-Script -Path $provide -Arguments $provideArgs
        $r.ExitCode | Should Be 0
        Test-Path -LiteralPath (Join-Path $root '.applied') | Should Be $true
        $r.Output | Should Match 'already applied'
    }
}

Describe 'apply-instrument-profiles.ps1' {
    $keyRoot = 'HKCU:\Software\MAST-Tests-' + [guid]::NewGuid().ToString('N')
    $profilesKey = Join-Path $keyRoot 'profile'
    $regRoot = $keyRoot -replace '^HKCU:', 'HKEY_CURRENT_USER'

    function New-Staging {
        param([string]$Name)
        $root = Join-Path $TestDrive $Name
        $settings = Join-Path $root 'PWI4\Settings'
        New-Item -ItemType Directory -Path $settings -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $settings 'PWI4.cfg') -Encoding ASCII -Value 'SerialPort = (template)'
        Set-Content -LiteralPath (Join-Path $settings 'EFA.Controller_1.cfg') -Encoding ASCII -Value 'SerialPort = (template)'
        Set-Content -LiteralPath (Join-Path $root 'phd2_profiles.reg') -Encoding Unicode -Value @(
            'Windows Registry Editor Version 5.00', '',
            ('[{0}\profile\1]' -f $regRoot), '"name"="template profile"', ''
        )
        return $root
    }

    function Get-ApplyArgs {
        param([string]$Root, [string]$Dest)
        return @('-ProfilesRoot', $Root, '-DestCfgDir', $Dest, '-Phd2ProfilesKey', $profilesKey, '-TaskName', $noTask)
    }

    It 'copies every template and imports the PHD2 profiles on a fresh unit' {
        $root = New-Staging -Name 'fresh'
        $dest = Join-Path $TestDrive 'fresh-live'
        (Invoke-Script -Path $apply -Arguments (Get-ApplyArgs $root $dest)).ExitCode | Should Be 0
        Test-Path -LiteralPath (Join-Path $dest 'PWI4.cfg') | Should Be $true
        Test-Path -LiteralPath (Join-Path $dest 'EFA.Controller_1.cfg') | Should Be $true
        (Get-ItemProperty -LiteralPath (Join-Path $profilesKey '1')).name | Should Be 'template profile'
        Test-Path -LiteralPath (Join-Path $root '.applied') | Should Be $true
    }

    It 'leaves live cfgs and existing PHD2 profiles alone, and copies only a missing cfg' {
        New-Item -Path (Join-Path $profilesKey '1') -Force | Out-Null
        Set-ItemProperty -LiteralPath (Join-Path $profilesKey '1') -Name 'name' -Value 'tuned on the unit'
        $root = New-Staging -Name 'deployed'
        $dest = Join-Path $TestDrive 'deployed-live'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dest 'EFA.Controller_1.cfg') -Encoding ASCII -Value 'SerialPort = COM7'
        $before = Get-Sha (Join-Path $dest 'EFA.Controller_1.cfg')

        (Invoke-Script -Path $apply -Arguments (Get-ApplyArgs $root $dest)).ExitCode | Should Be 0

        Get-Sha (Join-Path $dest 'EFA.Controller_1.cfg') | Should Be $before
        Test-Path -LiteralPath (Join-Path $dest 'PWI4.cfg') | Should Be $true
        (Get-ItemProperty -LiteralPath (Join-Path $profilesKey '1')).name | Should Be 'tuned on the unit'
        Test-Path -LiteralPath (Join-Path $root '.applied') | Should Be $true
    }

    It 'does nothing once the sentinel is present' {
        $root = New-Staging -Name 'applied'
        Set-Content -LiteralPath (Join-Path $root '.applied') -Value 'applied by a test'
        $dest = Join-Path $TestDrive 'applied-live'
        (Invoke-Script -Path $apply -Arguments (Get-ApplyArgs $root $dest)).ExitCode | Should Be 0
        Test-Path -LiteralPath $dest | Should Be $false
    }

    Remove-Item -LiteralPath $keyRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'verify-instrument-profiles.ps1' {
    $env:MAST_LOG_SESSION_DIR = Join-Path $TestDrive 'logs'
    $root = Join-Path $TestDrive 'verify-staging'
    Invoke-Script -Path $provide -Arguments @('-AssetsRoot', (New-Bundle -Name 'verify'), '-ProfilesRoot', $root, '-UnitToml', $nsToml, '-SkipTask') | Out-Null

    It 'fails a unit whose profiles are neither applied nor pending' {
        (Invoke-Script -Path $verify -Arguments @('-ProfilesRoot', $root, '-TaskName', $noTask)).ExitCode | Should Be 1
    }

    It 'passes an applied unit, whose apply task has unregistered itself' {
        Set-Content -LiteralPath (Join-Path $root '.applied') -Value 'applied by a test'
        (Invoke-Script -Path $verify -Arguments @('-ProfilesRoot', $root, '-TaskName', $noTask)).ExitCode | Should Be 0
    }
}
