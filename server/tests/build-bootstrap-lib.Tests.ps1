# Unit tests for build/build-bootstrap-lib.ps1 -- the bootstrap element-registry
# guard.
#
# The registry exists so tools/fleet-drift-report.py can tell an operator which
# bootstrap elements a unit is missing. Nothing ever forced it to be well-formed,
# and it drifted: three sections of bootstrap.ps1 had no element at all. These
# tests cover the half of that a build can check today -- shape, uniqueness, the
# reassert vocabulary, and the two version claims. Whether the registry COVERS
# the script is unprovable until the elements are dispatchable (#143 stage 2).
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
