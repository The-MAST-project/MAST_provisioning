# Bootstrap-registry helpers for build-mast.ps1. Dot-sourceable and
# side-effect-free so server/tests/build-bootstrap-lib.Tests.ps1 can exercise
# them without running a build; build-mast.ps1 dot-sources this file (single
# source of truth), the same arrangement build-staging-lib.ps1 has.
#
# WHY THIS EXISTS: client/bootstrap-elements.json is the registry of what a
# bootstrap of version N establishes, and tools/fleet-drift-report.py tells an
# operator which elements a unit is missing. Nothing has ever forced that
# registry to be COMPLETE or WELL-FORMED -- its 'id' is a label the report
# prints, matched against nothing (see MAST_provisioning#143). The registry duly
# drifted: three sections of bootstrap.ps1 had no element at all, one of them the
# automatic-DST assertion, so a unit missing it could not be reported as missing
# it.
#
# These checks are the half of that problem the build can see today. Whether the
# registry covers every section of the script cannot be checked until the
# elements are individually dispatchable -- that guard belongs with the
# extraction that makes it expressible, not here.

# The four values of an element's 'reassert' field. Says whether the element may
# be run again on an ALREADY-PROVISIONED unit -- the question a remote
# re-bootstrap has to answer per element, given some of them would cut the
# channel the run is travelling over.
$script:MastReassertKinds = @('routine', 'provider', 'on-demand', 'console')

function Get-MastBootstrapElementRegistry {
    <#
    .SYNOPSIS
      Parse client/bootstrap-elements.json.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("bootstrap element registry not found at {0}" -f $Path)
    }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Test-MastBootstrapElementRegistry {
    <#
    .SYNOPSIS
      Every problem with a parsed registry, as a list of strings. Empty = valid.
    .DESCRIPTION
      Pure: takes the parsed document, the provider names that exist, and the
      version bootstrap.ps1 embeds. Returns findings rather than throwing so the
      build can report all of them at once and the tests can assert on them.
    .PARAMETER KnownProviders
      Provider directory names. An element claiming reassert='provider' must name
      one that exists -- otherwise the claim "a provider already re-asserts this"
      is unverifiable prose, and the element silently gets re-asserted by nobody.
    .PARAMETER EmbeddedVersion
      $script:BootstrapVersion as it appears in bootstrap.ps1. Pass -1 to skip.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Registry,
        [string[]]$KnownProviders = @(),
        [int]$EmbeddedVersion = -1
    )

    $problems = @()
    $elements = @($Registry.elements)
    if ($elements.Count -eq 0) {
        return @('registry declares no elements')
    }

    $seen = @{}
    foreach ($e in $elements) {
        $id = [string]$e.id
        if ([string]::IsNullOrWhiteSpace($id)) {
            $problems += 'an element has no id'
            continue
        }
        if ($seen.ContainsKey($id)) { $problems += ("duplicate element id '{0}'" -f $id) }
        $seen[$id] = $true

        if ([string]::IsNullOrWhiteSpace([string]$e.description)) {
            $problems += ("element '{0}' has no description" -f $id)
        }

        $since = 0
        if ($e.PSObject.Properties.Match('since').Count) { $since = [int]$e.since }
        if ($since -lt 1) {
            $problems += ("element '{0}' has since={1}; must be >= 1" -f $id, $since)
        }

        if (-not $e.PSObject.Properties.Match('reassert').Count) {
            $problems += ("element '{0}' does not declare 'reassert' (one of: {1})" -f $id, ($script:MastReassertKinds -join ', '))
            continue
        }
        $kind = [string]$e.reassert
        if ($script:MastReassertKinds -notcontains $kind) {
            $problems += ("element '{0}' has reassert='{1}'; must be one of: {2}" -f $id, $kind, ($script:MastReassertKinds -join ', '))
            continue
        }

        $named = ''
        if ($e.PSObject.Properties.Match('provider').Count) { $named = [string]$e.provider }
        if ($kind -eq 'provider') {
            if ([string]::IsNullOrWhiteSpace($named)) {
                $problems += ("element '{0}' is reassert='provider' but names no 'provider'" -f $id)
            }
            elseif ($KnownProviders.Count -gt 0 -and $KnownProviders -notcontains $named) {
                $problems += ("element '{0}' names provider '{1}', which does not exist under server\providers" -f $id, $named)
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($named)) {
            $problems += ("element '{0}' names a provider but is reassert='{1}', not 'provider'" -f $id, $kind)
        }
    }

    # current_version is the registry's claim about the newest element it knows.
    # It is what the drift report compares a unit against, so a stale one
    # silently tells every unit it is current.
    $maxSince = (@($elements | ForEach-Object { [int]$_.since }) | Measure-Object -Maximum).Maximum
    $current = -1
    if ($Registry.PSObject.Properties.Match('current_version').Count) { $current = [int]$Registry.current_version }
    if ($current -ne $maxSince) {
        $problems += ("current_version is {0} but the newest element is since={1}" -f $current, $maxSince)
    }
    if ($EmbeddedVersion -ge 0 -and $current -ne $EmbeddedVersion) {
        $problems += ("current_version is {0} but bootstrap.ps1 `$script:BootstrapVersion is {1}; bump them together" -f $current, $EmbeddedVersion)
    }

    return $problems
}

function Get-MastBootstrapEmbeddedVersion {
    <#
    .SYNOPSIS
      $script:BootstrapVersion as literally written in bootstrap.ps1.
    .DESCRIPTION
      Parsed rather than dot-sourced: the script is admin-only and has side
      effects, the same reason Assert-BootstrapKnownSitesInSync parses.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BootstrapScript)

    if (-not (Test-Path -LiteralPath $BootstrapScript)) {
        throw ("Cannot read the bootstrap version: script not found at {0}" -f $BootstrapScript)
    }
    $text = Get-Content -LiteralPath $BootstrapScript -Raw -Encoding UTF8
    $m = [regex]::Match($text, '\$script:BootstrapVersion\s*=\s*(\d+)')
    if (-not $m.Success) {
        throw ("Cannot find a '`$script:BootstrapVersion = <n>' assignment in {0}." -f $BootstrapScript)
    }
    return [int]$m.Groups[1].Value
}

function Get-MastProviderNames {
    <#
    .SYNOPSIS
      Provider directory names under server\providers (those with a module.json).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProvidersRoot)

    if (-not (Test-Path -LiteralPath $ProvidersRoot)) { return @() }
    return @(
        Get-ChildItem -LiteralPath $ProvidersRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'module.json') } |
            ForEach-Object { $_.Name }
    )
}

function Assert-MastBootstrapElementRegistry {
    <#
    .SYNOPSIS
      Fail the build when the bootstrap element registry is malformed or stale.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClientRoot,
        [Parameter(Mandatory)][string]$ProvidersRoot
    )

    $registryPath = Join-Path $ClientRoot 'bootstrap-elements.json'
    $bootstrapScript = Join-Path $ClientRoot 'bootstrap.ps1'
    $registry = Get-MastBootstrapElementRegistry -Path $registryPath
    $embedded = Get-MastBootstrapEmbeddedVersion -BootstrapScript $bootstrapScript
    $providers = Get-MastProviderNames -ProvidersRoot $ProvidersRoot

    $problems = @(Test-MastBootstrapElementRegistry -Registry $registry -KnownProviders $providers -EmbeddedVersion $embedded)
    if ($problems.Count -gt 0) {
        throw ("{0} is invalid: {1}" -f $registryPath, ($problems -join '; '))
    }

    $counts = @{}
    foreach ($k in $script:MastReassertKinds) {
        $counts[$k] = @(@($registry.elements) | Where-Object { [string]$_.reassert -eq $k }).Count
    }
    Write-Host ('[build-mast] Bootstrap element registry valid: {0} elements at version {1} ({2}).' -f `
        @($registry.elements).Count, $embedded,
        (($script:MastReassertKinds | ForEach-Object { "$_=$($counts[$_])" }) -join ' '))
}
