# PSScriptAnalyzer configuration for MAST_provisioning.
#
# The PowerShell counterpart to ruff.toml, and the same doctrine: the rule set is
# recorded here rather than passed on a command line, the version is pinned (see
# tools/install-psscriptanalyzer.ps1 -- the default rule set moves between
# releases, exactly as it does for ruff), and what is deliberately NOT enforced is
# named with its reason instead of quietly dropped.
#
# Measured at adoption (PSSA 1.25.0, 113 tracked .ps1/.psm1): 742 findings with
# the defaults. 438 of those were one rule this repo has already decided against
# (see below), 114 were style/Information families, and 113 were empty catch
# blocks deferred to their own item. The remaining 77 were cleared. Rationale:
# docs/decisions/2026-08-18-powershell-is-linted-by-psscriptanalyzer.md
#
# Findings that are accepted rather than fixed are suppressed AT THE SITE with
# [Diagnostics.CodeAnalysis.SuppressMessageAttribute] and a justification, because
# PSScriptAnalyzer has no per-line suppression comment -- there is no `# noqa` or
# `# pyright: ignore` equivalent. Where a finding has no function or param block to
# attach an attribute to, it goes in tools/pssa-baseline.txt instead.
@{
    # Everything except the exclusions below. Severity is not filtered: an
    # Information-level finding from a rule we chose to run is still a finding.
    IncludeDefaultRules = $true

    ExcludeRules        = @(
        # 438 findings, and Write-Host is the CORRECT call here. These are
        # console-facing provisioning scripts whose output IS the operator
        # interface -- a technician watching a unit provision reads this. They are
        # not modules emitting objects into a pipeline, so Write-Output would put
        # log chatter into return values and break callers that read them.
        'PSAvoidUsingWriteHost',

        # 31. Same reason: these are scripts run to make a change, not cmdlets
        # offering -WhatIf. The provisioning contract is the run itself, and
        # server/prov/driver.py already owns dry-run at the level that matters.
        'PSUseShouldProcessForStateChangingFunctions',

        # 39. Positional arguments to external tools (net.exe, robocopy, nssm) are
        # how those tools are documented and invoked; naming them would obscure
        # rather than clarify.
        'PSAvoidUsingPositionalParameters',

        # 18. Comment-based help on internal helper functions inside one-purpose
        # provider scripts. The scripts carry .SYNOPSIS blocks; their private
        # helpers do not need one each.
        'PSProvideCommentHelp',

        # 18. Get-MastServiceNames returns four service names; Get-ConfiguredSites
        # returns a list of sites. The plural is accurate, and renaming to the
        # singular would make these read as single-item getters.
        'PSUseSingularNouns',

        # 8. Requires [OutputType()] on functions whose output is consumed inside
        # the same script. Documentation value here is close to zero.
        'PSUseOutputTypeCorrectly',

        # 12 findings, 12 of them WRONG -- verified individually. The rule does not
        # understand a param() block inside a scriptblock, which is how every
        # Start-Job and Invoke-Command in this repo passes its values:
        #
        #     Start-Job { param($a) & net.exe @a } -ArgumentList (,$ArgsList)
        #
        # It flags $a as needing $using:. It does not. The clincher: fixing a real
        # bug ($host shadowed in an Invoke-Command block, renamed to $unitHost)
        # ADDED a 12th false finding, because the automatic variable had been
        # invisible to the rule and a normal one is not. A rule that manufactures
        # findings from correct fixes cannot gate a codebase that is mostly
        # scriptblocks.
        'PSUseUsingScopeModifierInNewRunspaces',

        # 19 findings: 11 false (the parameter IS used, inside a switch body or a
        # scriptblock the rule's scope analysis does not follow -- build-mast's
        # -Site and -ImdiskMountType among them) and 8 real but harmless, every one
        # of the form "a caller passes a value this script ignores". Zero defects
        # in 19 findings, and the same scriptblock blindness as the rule above.
        #
        # The 8 are worth knowing even so, and are recorded in the decision record:
        # provide-phd2, provide-stage and provide-vscode ignore an -InstallRoot
        # their module.json passes; provide-npcap ignores -AssetsRoot;
        # mast-pull-staging ignores -UnitHostname (which transport.pull_staging_args
        # sends); and provide-openssh-server's -MastUser plus
        # provide-mast-validation's -TimeoutSeconds are accepted from nobody.
        'PSReviewUnusedParameter',

        # 113, and DEFERRED rather than dismissed -- this is the highest-value rule
        # in the set for this repo, because a swallowed error is precisely the
        # failure mode #55, #62 and #67-#69 all describe. It is scoped out here
        # only because 113 sites cannot be read inside the adoption that
        # introduces the tool, and each needs reading: some are deliberate
        # best-effort cleanup, some are bugs. Same shape as ruff's BLE001
        # deferral, and tracked with it in #92.
        'PSAvoidUsingEmptyCatchBlock'
    )
}
