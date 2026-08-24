# Unit tests for build/build-bootstrap-lib.ps1 -- the bootstrap element-registry
# guard.
#
# The registry exists so tools/fleet-drift-report.py can tell an operator which
# bootstrap elements a unit is missing. Nothing ever forced it to be well-formed,
# and it drifted: three sections of bootstrap.ps1 had no element at all.
#
# Two halves are covered here. Test-MastBootstrapElementRegistry checks the
# registry against itself -- shape, uniqueness, the reassert vocabulary, the two
# version claims. Test-MastBootstrapDispatchCoverage checks it against the
# SCRIPT, which only became possible once the re-assertable elements were
# extracted into functions addressed by id (#143 stage 2): every routine and
# on-demand element must be dispatchable, and nothing else may be.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\build-bootstrap-lib.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\..\build\build-bootstrap-lib.ps1')

function New-TestRegistry {
    param([int]$CurrentVersion = 2, [array]$Elements)
    if ($null -eq $Elements) {
        $Elements = @(
            [pscustomobject]@{ id = 'alpha'; since = 1; description = 'first'; reassert = 'routine' },
            [pscustomobject]@{ id = 'beta'; since = 2; description = 'second'; reassert = 'console' }
        )
    }
    return [pscustomobject]@{ current_version = $CurrentVersion; elements = $Elements }
}

Describe 'Test-MastBootstrapElementRegistry' {

    It 'accepts a well-formed registry' {
        @(Test-MastBootstrapElementRegistry -Registry (New-TestRegistry)).Count | Should Be 0
    }

    It 'rejects an element with no reassert declaration' {
        $r = New-TestRegistry -Elements @([pscustomobject]@{ id = 'alpha'; since = 1; description = 'x' })
        $r.current_version = 1
        (@(Test-MastBootstrapElementRegistry -Registry $r) -join ' ') | Should Match "does not declare 'reassert'"
    }

    It 'rejects an unknown reassert kind' {
        $r = New-TestRegistry -Elements @([pscustomobject]@{ id = 'alpha'; since = 1; description = 'x'; reassert = 'sometimes' })
        $r.current_version = 1
        (@(Test-MastBootstrapElementRegistry -Registry $r) -join ' ') | Should Match "must be one of"
    }

    It 'rejects a duplicate id' {
        $r = New-TestRegistry -Elements @(
            [pscustomobject]@{ id = 'alpha'; since = 1; description = 'x'; reassert = 'routine' },
            [pscustomobject]@{ id = 'alpha'; since = 1; description = 'y'; reassert = 'routine' }
        )
        $r.current_version = 1
        (@(Test-MastBootstrapElementRegistry -Registry $r) -join ' ') | Should Match 'duplicate element id'
    }

    It 'requires a provider-backed element to name its provider' {
        $r = New-TestRegistry -Elements @([pscustomobject]@{ id = 'alpha'; since = 1; description = 'x'; reassert = 'provider' })
        $r.current_version = 1
        (@(Test-MastBootstrapElementRegistry -Registry $r) -join ' ') | Should Match "names no 'provider'"
    }

    It 'requires the named provider to exist' {
        # Otherwise "a provider already re-asserts this" is unverifiable prose,
        # and the element is quietly re-asserted by nobody.
        $r = New-TestRegistry -Elements @([pscustomobject]@{ id = 'alpha'; since = 1; description = 'x'; reassert = 'provider'; provider = 'ghost' })
        $r.current_version = 1
        (@(Test-MastBootstrapElementRegistry -Registry $r -KnownProviders @('timesync')) -join ' ') | Should Match 'does not exist'
    }

    It 'accepts a provider-backed element naming a real provider' {
        $r = New-TestRegistry -Elements @([pscustomobject]@{ id = 'alpha'; since = 1; description = 'x'; reassert = 'provider'; provider = 'timesync' })
        $r.current_version = 1
        @(Test-MastBootstrapElementRegistry -Registry $r -KnownProviders @('timesync')).Count | Should Be 0
    }

    It 'rejects a provider name on an element that is not provider-backed' {
        $r = New-TestRegistry -Elements @([pscustomobject]@{ id = 'alpha'; since = 1; description = 'x'; reassert = 'routine'; provider = 'timesync' })
        $r.current_version = 1
        (@(Test-MastBootstrapElementRegistry -Registry $r -KnownProviders @('timesync')) -join ' ') | Should Match 'names a provider but is'
    }

    It 'rejects a current_version behind the newest element' {
        # A stale current_version silently tells every unit it is up to date.
        (@(Test-MastBootstrapElementRegistry -Registry (New-TestRegistry -CurrentVersion 1)) -join ' ') |
            Should Match 'newest element is since=2'
    }

    It 'rejects a current_version that disagrees with bootstrap.ps1' {
        (@(Test-MastBootstrapElementRegistry -Registry (New-TestRegistry) -EmbeddedVersion 7) -join ' ') |
            Should Match 'bump them together'
    }

    It 'skips the bootstrap.ps1 comparison when no version is supplied' {
        @(Test-MastBootstrapElementRegistry -Registry (New-TestRegistry) -EmbeddedVersion -1).Count | Should Be 0
    }

    It 'rejects a since below 1' {
        $r = New-TestRegistry -Elements @([pscustomobject]@{ id = 'alpha'; since = 0; description = 'x'; reassert = 'routine' })
        $r.current_version = 0
        (@(Test-MastBootstrapElementRegistry -Registry $r) -join ' ') | Should Match 'must be >= 1'
    }
}

Describe 'the real bootstrap element registry' {

    It 'is valid, and every provider it names exists' {
        $client = Join-Path $here '..\..\client'
        $providers = Join-Path $here '..\providers'
        $registry = Get-MastBootstrapElementRegistry -Path (Join-Path $client 'bootstrap-elements.json')
        $embedded = Get-MastBootstrapEmbeddedVersion -BootstrapScript (Join-Path $client 'bootstrap.ps1')
        $known = Get-MastProviderNames -ProvidersRoot $providers
        $known.Count -gt 0 | Should Be $true
        @(Test-MastBootstrapElementRegistry -Registry $registry -KnownProviders $known -EmbeddedVersion $embedded).Count | Should Be 0
    }

    It 'classifies every element it declares' {
        $client = Join-Path $here '..\..\client'
        $registry = Get-MastBootstrapElementRegistry -Path (Join-Path $client 'bootstrap-elements.json')
        foreach ($e in @($registry.elements)) {
            @('routine', 'provider', 'on-demand', 'console') -contains [string]$e.reassert | Should Be $true
        }
    }

    It 'keeps the two transport elements off the routine path' {
        # MAST_provisioning#123: mast06 finished a "clean" bootstrap with no SSH
        # server. Reinstalling the transport under a live session is how a
        # healthy unit becomes an unreachable one, so neither may be routine.
        $client = Join-Path $here '..\..\client'
        $registry = Get-MastBootstrapElementRegistry -Path (Join-Path $client 'bootstrap-elements.json')
        foreach ($id in @('winrm-http-basic', 'openssh-from-msi')) {
            $e = @($registry.elements) | Where-Object { $_.id -eq $id }
            $e | Should Not BeNullOrEmpty
            [string]$e.reassert | Should Be 'on-demand'
        }
    }
}

Describe 'Test-MastBootstrapDispatchCoverage' {

    function New-CoverageRegistry {
        return [pscustomobject]@{ current_version = 1; elements = @(
            [pscustomobject]@{ id = 'routine-one'; since = 1; description = 'x'; reassert = 'routine' },
            [pscustomobject]@{ id = 'repair-one'; since = 1; description = 'x'; reassert = 'on-demand' },
            [pscustomobject]@{ id = 'console-one'; since = 1; description = 'x'; reassert = 'console' },
            [pscustomobject]@{ id = 'provider-one'; since = 1; description = 'x'; reassert = 'provider'; provider = 'timesync' }
        ) }
    }

    It 'accepts a map covering exactly the re-assertable elements' {
        $map = [ordered]@{ 'routine-one' = @{ Kind = 'routine'; Function = 'Invoke-A' }; 'repair-one' = @{ Kind = 'on-demand'; Function = 'Invoke-B' } }
        @(Test-MastBootstrapDispatchCoverage -Registry (New-CoverageRegistry) -DispatchMap $map).Count | Should Be 0
    }

    It 'rejects a routine element the script cannot dispatch' {
        # A re-assert run would silently skip it -- the failure this whole
        # mechanism exists to make impossible.
        $map = [ordered]@{ 'repair-one' = @{ Kind = 'on-demand'; Function = 'Invoke-B' } }
        (@(Test-MastBootstrapDispatchCoverage -Registry (New-CoverageRegistry) -DispatchMap $map) -join ' ') |
            Should Match "does not dispatch it"
    }

    It 'rejects a console element being made dispatchable' {
        # Reaching a first-touch element remotely is the failure mode the
        # classification exists to prevent.
        $map = [ordered]@{ 'routine-one' = 'Invoke-A'; 'repair-one' = 'Invoke-B'; 'console-one' = @{ Kind = 'console'; Function = 'Invoke-C' } }
        (@(Test-MastBootstrapDispatchCoverage -Registry (New-CoverageRegistry) -DispatchMap $map) -join ' ') |
            Should Match "only routine and on-demand elements may be dispatchable"
    }

    It 'rejects a provider-backed element being made dispatchable' {
        $map = [ordered]@{ 'routine-one' = 'Invoke-A'; 'repair-one' = 'Invoke-B'; 'provider-one' = @{ Kind = 'provider'; Function = 'Invoke-D' } }
        (@(Test-MastBootstrapDispatchCoverage -Registry (New-CoverageRegistry) -DispatchMap $map) -join ' ') |
            Should Match "only routine and on-demand elements may be dispatchable"
    }

    It 'rejects a dispatched id that is not an element at all' {
        $map = [ordered]@{ 'routine-one' = 'Invoke-A'; 'repair-one' = 'Invoke-B'; 'ghost' = @{ Kind = 'routine'; Function = 'Invoke-E' } }
        (@(Test-MastBootstrapDispatchCoverage -Registry (New-CoverageRegistry) -DispatchMap $map) -join ' ') |
            Should Match "not an element in the registry"
    }

    It 'rejects an embedded Kind that disagrees with the registry' {
        # bootstrap embeds the classification because it runs offline and cannot
        # read the registry. A console element mislabelled 'routine' in that copy
        # would be re-asserted remotely -- the one thing the split forbids.
        $map = [ordered]@{ 'routine-one' = @{ Kind = 'on-demand'; Function = 'Invoke-A' }; 'repair-one' = @{ Kind = 'on-demand'; Function = 'Invoke-B' } }
        (@(Test-MastBootstrapDispatchCoverage -Registry (New-CoverageRegistry) -DispatchMap $map) -join ' ') |
            Should Match "Kind='on-demand' in bootstrap.ps1"
    }

    It 'rejects a map naming a function the script does not define' {
        $map = [ordered]@{ 'routine-one' = @{ Kind = 'routine'; Function = 'Invoke-A' }; 'repair-one' = @{ Kind = 'on-demand'; Function = 'Invoke-B' } }
        $text = "function Invoke-A {`n}`n"
        (@(Test-MastBootstrapDispatchCoverage -Registry (New-CoverageRegistry) -DispatchMap $map -ScriptText $text) -join ' ') |
            Should Match "which is not defined in bootstrap.ps1"
    }
}

Describe 'the real dispatch map' {

    It 'covers every re-assertable element and nothing else' {
        $client = Join-Path $here '..\..\client'
        $script = Join-Path $client 'bootstrap.ps1'
        $registry = Get-MastBootstrapElementRegistry -Path (Join-Path $client 'bootstrap-elements.json')
        $map = Get-MastBootstrapDispatchMap -BootstrapScript $script
        $text = Get-Content -LiteralPath $script -Raw -Encoding UTF8
        @(Test-MastBootstrapDispatchCoverage -Registry $registry -DispatchMap $map -ScriptText $text).Count | Should Be 0
    }

    It 'dispatches ten elements' {
        $map = Get-MastBootstrapDispatchMap -BootstrapScript (Join-Path $here '..\..\client\bootstrap.ps1')
        $map.Count | Should Be 10
    }

    It 'embeds a Kind matching the registry for every dispatched element' {
        $client = Join-Path $here '..\..\client'
        $registry = Get-MastBootstrapElementRegistry -Path (Join-Path $client 'bootstrap-elements.json')
        $map = Get-MastBootstrapDispatchMap -BootstrapScript (Join-Path $client 'bootstrap.ps1')
        foreach ($id in $map.Keys) {
            $e = @($registry.elements) | Where-Object { $_.id -eq $id }
            [string]$map[$id].Kind | Should Be ([string]$e.reassert)
        }
    }

    It 'does not dispatch the console elements' {
        $map = Get-MastBootstrapDispatchMap -BootstrapScript (Join-Path $here '..\..\client\bootstrap.ps1')
        foreach ($id in @('mast-admin-account', 'auto-logon', 'computer-rename', 'npcap', 'hardware-preflight', 'bootstrap-media-handling')) {
            $map.Contains($id) | Should Be $false
        }
    }
}
