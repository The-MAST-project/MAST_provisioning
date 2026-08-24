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
# Two halves are checked here. Test-MastBootstrapElementRegistry holds the
# registry to itself; Test-MastBootstrapDispatchCoverage holds it to the SCRIPT,
# which became expressible once the re-assertable elements were extracted into
# functions addressed by id. The second also guards the classification bootstrap
# EMBEDS: it runs offline from removable media and cannot read the registry, so
# it carries a copy, and a copy that drifts silently is worse than no copy --
# a console element mislabelled 'routine' would be re-asserted remotely.
#
# Still not checked: whether the registry covers every SECTION of the script.
# The console elements remain inline, so nothing forces a new one to be
# registered. That needs a different mechanism than id correspondence.

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

function Get-MastBootstrapDispatchMap {
    <#
    .SYNOPSIS
      The id -> function map bootstrap.ps1 declares, as an ordered hashtable.
    .DESCRIPTION
      Parsed, not dot-sourced: bootstrap.ps1 is admin-only and has side effects,
      the same reason the site-list and memory-figure guards parse.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BootstrapScript)

    if (-not (Test-Path -LiteralPath $BootstrapScript)) {
        throw ("Cannot read the element dispatch map: script not found at {0}" -f $BootstrapScript)
    }
    $text = Get-Content -LiteralPath $BootstrapScript -Raw -Encoding UTF8
    $block = [regex]::Match($text, '\$script:MastBootstrapElementActions\s*=\s*\[ordered\]@\{(.*?)^\}', 'Singleline,Multiline')
    if (-not $block.Success) {
        throw ("Cannot find a '`$script:MastBootstrapElementActions = [ordered]@{...}' map in {0}." -f $BootstrapScript)
    }
    $map = [ordered]@{}
    $rx = "'([\w-]+)'\s*=\s*@\{\s*Kind\s*=\s*'([\w-]+)'\s*;\s*Function\s*=\s*'([\w-]+)'\s*\}"
    foreach ($m in [regex]::Matches($block.Groups[1].Value, $rx)) {
        $map[$m.Groups[1].Value] = @{ Kind = $m.Groups[2].Value; Function = $m.Groups[3].Value }
    }
    return $map
}

function Test-MastBootstrapDispatchCoverage {
    <#
    .SYNOPSIS
      Every problem with the registry-to-script correspondence. Empty = valid.
    .DESCRIPTION
      THE CHECK THE REGISTRY NEVER HAD. Its 'id' was a label the drift report
      printed, matched against nothing in bootstrap.ps1, so the registry could
      silently stop describing the script -- and did, for three elements.
      Now that the re-assertable elements are functions addressed by id, the two
      can be held to each other.

      Scope is exactly the re-assertable set: an element marked 'routine' or
      'on-demand' MUST be dispatchable, because a re-assert run has to be able to
      call it. 'console' and 'provider' elements must NOT be, because nothing may
      invoke them that way -- a console element reached remotely is the failure
      this design exists to prevent.
    .PARAMETER ScriptText
      The full text of bootstrap.ps1, for confirming each mapped function exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)]$DispatchMap,
        [string]$ScriptText = ''
    )

    $problems = @()
    $reassertable = @{}
    foreach ($e in @($Registry.elements)) {
        $kind = [string]$e.reassert
        if ($kind -eq 'routine' -or $kind -eq 'on-demand') { $reassertable[[string]$e.id] = $kind }
    }

    foreach ($id in $reassertable.Keys) {
        if (-not $DispatchMap.Contains($id)) {
            $problems += ("element '{0}' is reassert='{1}' but bootstrap.ps1 does not dispatch it; a re-assert run could not call it" -f $id, $reassertable[$id])
        }
    }
    foreach ($id in $DispatchMap.Keys) {
        if (-not $reassertable.ContainsKey($id)) {
            $known = @(@($Registry.elements) | Where-Object { [string]$_.id -eq $id })
            if ($known.Count -eq 0) {
                $problems += ("bootstrap.ps1 dispatches '{0}', which is not an element in the registry" -f $id)
            }
            else {
                $problems += ("bootstrap.ps1 dispatches '{0}', but the registry marks it reassert='{1}'; only routine and on-demand elements may be dispatchable" -f $id, [string]$known[0].reassert)
            }
        }
        # The embedded Kind is a COPY of the registry's classification -- bootstrap
        # runs offline and cannot read the registry, the same constraint
        # $knownSites has. A copy that can drift silently is worse than no copy:
        # a console element mis-labelled 'routine' here would be re-asserted
        # remotely, which is the one thing the classification forbids.
        if ($reassertable.ContainsKey($id)) {
            $embeddedKind = [string]$DispatchMap[$id].Kind
            if ($embeddedKind -ne $reassertable[$id]) {
                $problems += ("element '{0}' is reassert='{1}' in the registry but Kind='{2}' in bootstrap.ps1" -f $id, $reassertable[$id], $embeddedKind)
            }
        }
        if ($ScriptText) {
            $fn = [string]$DispatchMap[$id].Function
            if ($ScriptText -notmatch ('(?m)^function\s+' + [regex]::Escape($fn) + '\s*\{')) {
                $problems += ("element '{0}' maps to function '{1}', which is not defined in bootstrap.ps1" -f $id, $fn)
            }
        }
    }
    return $problems
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

    $dispatch = Get-MastBootstrapDispatchMap -BootstrapScript $bootstrapScript
    $scriptText = Get-Content -LiteralPath $bootstrapScript -Raw -Encoding UTF8
    $coverage = @(Test-MastBootstrapDispatchCoverage -Registry $registry -DispatchMap $dispatch -ScriptText $scriptText)
    if ($coverage.Count -gt 0) {
        throw ("{0} and {1} disagree: {2}" -f $registryPath, $bootstrapScript, ($coverage -join '; '))
    }

    $counts = @{}
    foreach ($k in $script:MastReassertKinds) {
        $counts[$k] = @(@($registry.elements) | Where-Object { [string]$_.reassert -eq $k }).Count
    }
    Write-Host ('[build-mast] Bootstrap element registry valid: {0} elements at version {1} ({2}); {3} dispatchable.' -f `
        @($registry.elements).Count, $embedded,
        (($script:MastReassertKinds | ForEach-Object { "$_=$($counts[$_])" }) -join ' '),
        $dispatch.Count)
}
