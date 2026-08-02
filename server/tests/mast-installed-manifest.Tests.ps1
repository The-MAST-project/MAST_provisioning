# Unit tests for client/mast-installed-manifest.ps1 -- the cumulative per-module
# installed-manifest merge (issue #22 stage 2).
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\mast-installed-manifest.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\..\client\mast-installed-manifest.ps1')

$AT = '2026-08-02T10:00:00Z'
$EARLIER = '2026-07-01T09:00:00Z'

function New-BuildData {
    param([string[]]$Modules, [hashtable]$Hashes, [string]$PayloadHash = 'aggregate-hash')
    $state = @{}
    foreach ($m in $Modules) {
        $state[$m] = [pscustomobject]@{ version = '1.0'; hash = $Hashes[$m] }
    }
    return [pscustomobject]@{
        built_at     = '2026-08-02T09:00:00Z'
        git_sha      = 'abc1234'
        hostname     = 'mast01'
        payload_hash = $PayloadHash
        modules      = $Modules
        module_state = [pscustomobject]$state
    }
}

function New-Outcomes {
    param([hashtable]$Spec)   # module -> @(provideSuccess, verifySuccess-or-$null)
    $o = New-MastModuleOutcomeMap
    foreach ($m in $Spec.Keys) {
        $o = Add-MastModuleOutcome -Outcomes $o -CommandModule $m -Success $Spec[$m][0]
        if ($null -ne $Spec[$m][1]) {
            $o = Add-MastModuleOutcome -Outcomes $o -CommandModule "$m-verify" -Success $Spec[$m][1]
        }
    }
    return $o
}

Describe 'Add-MastModuleOutcome' {
    It 'splits provide and verify by the -verify suffix' {
        $o = New-Outcomes @{ 'git' = @($true, $true) }
        $o['git']['provide'] | Should Be 'pass'
        $o['git']['verify']  | Should Be 'pass'
    }
    It "records verify 'none' when the module has no verify command" {
        # Absence of a check must not read as a passed check.
        $o = New-Outcomes @{ 'git' = @($true, $null) }
        $o['git']['verify'] | Should Be 'none'
    }
    It 'a failure is sticky -- a later passing command cannot mask it' {
        $o = New-MastModuleOutcomeMap
        $o = Add-MastModuleOutcome -Outcomes $o -CommandModule 'git' -Success $false
        $o = Add-MastModuleOutcome -Outcomes $o -CommandModule 'git' -Success $true
        $o['git']['provide'] | Should Be 'fail'
    }
}

Describe 'Merge-MastInstalledManifest -- the last-payload-only fix' {
    It 'preserves untouched modules when only a subset runs' {
        # THE bug this stage exists to fix: a -Modules subset used to overwrite
        # the whole document, so the unit forgot everything else it had.
        $build = New-BuildData -Modules @('git', 'python') -Hashes @{ git = 'h-git'; python = 'h-py' }
        $first = Merge-MastInstalledManifest -Previous $null -BuildData $build `
                    -Outcomes (New-Outcomes @{ 'git' = @($true, $true); 'python' = @($true, $true) }) `
                    -InstalledAt $EARLIER
        # Round-trip through JSON: that is how the next run reads it.
        $prev = $first | ConvertTo-Json -Depth 6 | ConvertFrom-Json

        $second = Merge-MastInstalledManifest -Previous $prev -BuildData $build `
                    -Outcomes (New-Outcomes @{ 'git' = @($true, $true) }) -InstalledAt $AT

        $second.modules.python.hash         | Should Be 'h-py'
        $second.modules.python.installed_at | Should Be $EARLIER
        $second.modules.git.installed_at    | Should Be $AT
        $second.fully_provisioned           | Should Be $true
    }
    It 'takes version and hash from the build module_state' {
        $build = New-BuildData -Modules @('git') -Hashes @{ git = 'h-git' }
        $r = Merge-MastInstalledManifest -Previous $null -BuildData $build `
                -Outcomes (New-Outcomes @{ 'git' = @($true, $true) }) -InstalledAt $AT
        $r.modules.git.hash    | Should Be 'h-git'
        $r.modules.git.version | Should Be '1.0'
    }
}

Describe 'Merge-MastInstalledManifest -- partial runs' {
    It 'records a failed module rather than skipping the write entirely' {
        $build = New-BuildData -Modules @('git', 'python') -Hashes @{ git = 'h-git'; python = 'h-py' }
        $r = Merge-MastInstalledManifest -Previous $null -BuildData $build `
                -Outcomes (New-Outcomes @{ 'git' = @($true, $true); 'python' = @($false, $null) }) `
                -InstalledAt $AT
        $r.modules.python.provide | Should Be 'fail'
        $r.modules.git.provide    | Should Be 'pass'
    }
    It 'withholds payload_hash on a partial run so the fast path cannot skip the unit' {
        # check-and-provision.ps1 / driver.py compare payload_hash to decide
        # "nothing changed". Publishing it after a partial run would strand a
        # unit that still needs work.
        $build = New-BuildData -Modules @('git', 'python') -Hashes @{ git = 'h-git'; python = 'h-py' }
        $r = Merge-MastInstalledManifest -Previous $null -BuildData $build `
                -Outcomes (New-Outcomes @{ 'git' = @($true, $true); 'python' = @($false, $null) }) `
                -InstalledAt $AT
        $r.fully_provisioned | Should Be $false
        $r.PSObject.Properties.Match('payload_hash').Count | Should Be 0
    }
    It 'publishes payload_hash once every build module is present and clean' {
        $build = New-BuildData -Modules @('git') -Hashes @{ git = 'h-git' }
        $r = Merge-MastInstalledManifest -Previous $null -BuildData $build `
                -Outcomes (New-Outcomes @{ 'git' = @($true, $true) }) -InstalledAt $AT
        $r.fully_provisioned | Should Be $true
        $r.payload_hash      | Should Be 'aggregate-hash'
    }
    It 'a failed verify blocks fully_provisioned even though provide passed' {
        $build = New-BuildData -Modules @('git') -Hashes @{ git = 'h-git' }
        $r = Merge-MastInstalledManifest -Previous $null -BuildData $build `
                -Outcomes (New-Outcomes @{ 'git' = @($true, $false) }) -InstalledAt $AT
        $r.fully_provisioned | Should Be $false
    }
    It "a module with no verify ('none') does not block fully_provisioned" {
        $build = New-BuildData -Modules @('git') -Hashes @{ git = 'h-git' }
        $r = Merge-MastInstalledManifest -Previous $null -BuildData $build `
                -Outcomes (New-Outcomes @{ 'git' = @($true, $null) }) -InstalledAt $AT
        $r.fully_provisioned | Should Be $true
    }
    It 'a module the build declares but the run never touched blocks fully_provisioned' {
        $build = New-BuildData -Modules @('git', 'python') -Hashes @{ git = 'h-git'; python = 'h-py' }
        $r = Merge-MastInstalledManifest -Previous $null -BuildData $build `
                -Outcomes (New-Outcomes @{ 'git' = @($true, $true) }) -InstalledAt $AT
        $r.fully_provisioned | Should Be $false
    }
    It 'a carried-forward entry whose hash no longer matches the build blocks fully_provisioned' {
        # The unit installed python from an older payload; the build moved on.
        $old = New-BuildData -Modules @('git', 'python') -Hashes @{ git = 'h-git'; python = 'h-py-OLD' }
        $prev = (Merge-MastInstalledManifest -Previous $null -BuildData $old `
                    -Outcomes (New-Outcomes @{ 'git' = @($true, $true); 'python' = @($true, $true) }) `
                    -InstalledAt $EARLIER) | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        $new = New-BuildData -Modules @('git', 'python') -Hashes @{ git = 'h-git'; python = 'h-py-NEW' }
        $r = Merge-MastInstalledManifest -Previous $prev -BuildData $new `
                -Outcomes (New-Outcomes @{ 'git' = @($true, $true) }) -InstalledAt $AT
        $r.fully_provisioned | Should Be $false
    }
}

Describe 'Merge-MastInstalledManifest -- legacy manifest migration' {
    It 'handles the pre-module_state whole-document manifest without crashing' {
        # mast01-04 carry a copy of build-manifest.json plus installed_at, with
        # no 'modules' map. Nothing to carry forward; coverage starts here and
        # stage 3 treats the rest as missing.
        $legacy = [pscustomobject]@{
            built_at     = '2026-06-01T00:00:00Z'
            git_sha      = 'old1234'
            payload_hash = 'old-aggregate'
            installed_at = '2026-06-01T01:00:00Z'
        }
        $build = New-BuildData -Modules @('git', 'python') -Hashes @{ git = 'h-git'; python = 'h-py' }
        $r = Merge-MastInstalledManifest -Previous $legacy -BuildData $build `
                -Outcomes (New-Outcomes @{ 'git' = @($true, $true) }) -InstalledAt $AT
        $r.modules.git.hash  | Should Be 'h-git'
        $r.fully_provisioned | Should Be $false
        @($r.modules.PSObject.Properties).Count | Should Be 1
    }
    It 'does not inherit the legacy payload_hash on a partial run' {
        # Inheriting it would tell the fast path the unit is current.
        $legacy = [pscustomobject]@{ payload_hash = 'old-aggregate' }
        $build = New-BuildData -Modules @('git', 'python') -Hashes @{ git = 'h-git'; python = 'h-py' }
        $r = Merge-MastInstalledManifest -Previous $legacy -BuildData $build `
                -Outcomes (New-Outcomes @{ 'git' = @($true, $true) }) -InstalledAt $AT
        $r.PSObject.Properties.Match('payload_hash').Count | Should Be 0
    }
}
