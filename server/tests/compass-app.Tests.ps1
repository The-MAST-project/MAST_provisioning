# Pester unit tests for the Compass app-directory locator in
# server/providers/mongodb-client/compass-app.ps1.
#
# The bug these exist for: the provider took Get-ChildItem's first 'app-*'
# result, and on mast07 -- which had self-updated from 1.43.0 to 1.49.14 --
# 'app-1.43.0' sorts first, so the size assertions measured a superseded tree
# while the unit ran a live one. Issue #137.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\compass-app.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\providers\mongodb-client\compass-app.ps1')

function New-CompassTree {
    # Build a throwaway Compass install root. -Dirs takes names; a name suffixed
    # with '!' gets a '.dead' marker, the way Squirrel marks a superseded build.
    param([string[]]$Dirs)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('compass-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    foreach ($d in $Dirs) {
        $dead = $d.EndsWith('!')
        $name = if ($dead) { $d.TrimEnd('!') } else { $d }
        $p = Join-Path $root $name
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        if ($dead) { Set-Content -LiteralPath (Join-Path $p '.dead') -Value '' }
    }
    return $root
}

Describe 'Get-MastCompassVersionFromName' {
    It 'reads an app directory name' {
        (Get-MastCompassVersionFromName -Name 'app-1.49.14') | Should Be ([version]'1.49.14')
    }
    It 'reads the installer asset name' {
        (Get-MastCompassVersionFromName -Name 'mongodb-compass-1.43.0-win32-x64.exe') | Should Be ([version]'1.43.0')
    }
    It 'takes the numeric part of a prerelease name' {
        (Get-MastCompassVersionFromName -Name 'app-1.44.0-beta.1') | Should Be ([version]'1.44.0')
    }
    It 'returns null when there is no version to read' {
        (Get-MastCompassVersionFromName -Name 'app-current') | Should BeNullOrEmpty
    }
    It 'returns null on empty input' {
        (Get-MastCompassVersionFromName -Name '') | Should BeNullOrEmpty
    }
}

Describe 'Get-MastCompassApp' {
    It 'picks the only build on an undrifted unit' {
        $root = New-CompassTree -Dirs @('app-1.43.0')
        try {
            $app = Get-MastCompassApp -CompassRoot $root
            $app.Name | Should Be 'app-1.43.0'
            $app.Superseded.Count | Should Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'picks the newer build, not the alphabetically first (the mast07 case)' {
        # 'app-1.43.0' -lt 'app-1.49.14' as strings, which is what the old code took.
        $root = New-CompassTree -Dirs @('app-1.43.0', 'app-1.49.14')
        try {
            $app = Get-MastCompassApp -CompassRoot $root
            $app.Version | Should Be ([version]'1.49.14')
            $app.Superseded.Count | Should Be 1
            $app.Superseded[0].Name | Should Be 'app-1.43.0'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'compares versions numerically, not as text' {
        # '1.9.0' -gt '1.10.0' as strings; 1.10.0 is the newer build.
        $root = New-CompassTree -Dirs @('app-1.9.0', 'app-1.10.0')
        try {
            (Get-MastCompassApp -CompassRoot $root).Version | Should Be ([version]'1.10.0')
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'skips a build Squirrel marked dead' {
        $root = New-CompassTree -Dirs @('app-1.43.0', 'app-1.49.14!')
        try {
            (Get-MastCompassApp -CompassRoot $root).Version | Should Be ([version]'1.43.0')
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'reports a dead build as superseded rather than dropping it' {
        $root = New-CompassTree -Dirs @('app-1.43.0!', 'app-1.49.14')
        try {
            $app = Get-MastCompassApp -CompassRoot $root
            $app.Version | Should Be ([version]'1.49.14')
            $app.All.Count | Should Be 2
            @($app.Superseded | Where-Object { $_.IsDead }).Count | Should Be 1
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'falls back to an unparseable name rather than claiming nothing is installed' {
        $root = New-CompassTree -Dirs @('app-current')
        try {
            $app = Get-MastCompassApp -CompassRoot $root
            $app.Name | Should Be 'app-current'
            $app.Version | Should BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'prefers a parseable live build over an unparseable one' {
        $root = New-CompassTree -Dirs @('app-current', 'app-1.43.0')
        try {
            (Get-MastCompassApp -CompassRoot $root).Name | Should Be 'app-1.43.0'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'returns a null path when no build is present' {
        $root = New-CompassTree -Dirs @()
        try {
            $app = Get-MastCompassApp -CompassRoot $root
            $app.Path | Should BeNullOrEmpty
            $app.All.Count | Should Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'returns a null path for a root that does not exist' {
        $app = Get-MastCompassApp -CompassRoot (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N')))
        $app.Path | Should BeNullOrEmpty
    }
    It 'ignores directories that are not app-*' {
        $root = New-CompassTree -Dirs @('app-1.43.0', 'packages')
        try {
            (Get-MastCompassApp -CompassRoot $root).All.Count | Should Be 1
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Describe 'Get-MastCompassPin' {
    It 'reads the pinned version off the staged installer' {
        $root = New-CompassTree -Dirs @()
        try {
            Set-Content -LiteralPath (Join-Path $root 'mongodb-compass-1.43.0-win32-x64.exe') -Value 'x'
            (Get-MastCompassPin -AssetsRoot $root).Version | Should Be ([version]'1.43.0')
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'reports a null version when the installer is not staged' {
        $root = New-CompassTree -Dirs @()
        try {
            (Get-MastCompassPin -AssetsRoot $root).Version | Should BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}
