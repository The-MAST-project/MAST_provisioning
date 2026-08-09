# Cumulative per-module installed-manifest for the unit.
#
# Dot-sourced by client/execute-mast-provisioning.ps1 (staged beside it) and by
# server/tests/mast-installed-manifest.Tests.ps1, so the merge semantics are
# tested without running a provisioning cycle.
#
# WHY THIS EXISTS: execute used to copy build-manifest.json wholesale and stamp
# installed_at, which made the record LAST-PAYLOAD-ONLY -- a `-Modules <subset>`
# touch-up overwrote the document with just that subset, and the unit could no
# longer answer "am I fully provisioned". This module merges per-module entries
# instead, so an untouched module's record survives a partial run.
# See docs/per-module-tracking-plan.md Stage 2, issue #22.

Set-StrictMode -Off

# Per-module entry state. 'provide' and 'verify' are tracked separately because
# a module can install and then fail its own verify, and because a module may
# have no verify command at all (verify = 'none' rather than a false 'pass').
$script:MastModulePass = 'pass'
$script:MastModuleFail = 'fail'
$script:MastModuleNone = 'none'

function New-MastModuleOutcomeMap {
    # Ordered so the manifest reads in execution order for a human.
    return [ordered]@{}
}

# Record one command's result. Called once per command in the execute loop.
# The '-verify' suffix on a command's module name is how commands.json marks a
# verify step (the same convention the -Modules filter uses).
function Add-MastModuleOutcome {
    param(
        [Parameter(Mandatory)]$Outcomes,
        [Parameter(Mandatory)][string]$CommandModule,
        [Parameter(Mandatory)][bool]$Success
    )

    $isVerify = $CommandModule -like '*-verify'
    $base = if ($isVerify) { $CommandModule.Substring(0, $CommandModule.Length - 7) } else { $CommandModule }

    if (-not $Outcomes.Contains($base)) {
        $Outcomes[$base] = [ordered]@{
            provide = $script:MastModuleNone
            verify  = $script:MastModuleNone
        }
    }

    $key = if ($isVerify) { 'verify' } else { 'provide' }
    # A module can contribute several commands of the same kind; any failure
    # among them is a failure for the module. Never let a later pass overwrite
    # an earlier fail.
    if (-not $Success) {
        $Outcomes[$base][$key] = $script:MastModuleFail
    }
    elseif ($Outcomes[$base][$key] -ne $script:MastModuleFail) {
        $Outcomes[$base][$key] = $script:MastModulePass
    }

    return $Outcomes
}

# Merge this run's outcomes into the prior installed manifest.
#
#   $Previous     parsed installed-manifest.json, or $null on a first run
#   $BuildData    parsed build-manifest.json for the payload just executed
#   $Outcomes     map from Add-MastModuleOutcome (modules ACTUALLY run)
#   $InstalledAt  UTC stamp string, injected so tests are deterministic
#
# Modules absent from $Outcomes keep their previous entry verbatim -- that is
# the whole point: a `-Modules openssh-server` run no longer erases what the
# other twenty modules reported.
function Merge-MastInstalledManifest {
    param(
        $Previous,
        [Parameter(Mandatory)]$BuildData,
        [Parameter(Mandatory)]$Outcomes,
        [Parameter(Mandatory)][string]$InstalledAt
    )

    $modules = [ordered]@{}

    # 1. Carry forward everything the unit previously recorded. A legacy manifest
    #    (pre-module_state, i.e. the whole-document copy) has no 'modules' key --
    #    there is simply nothing to carry, and the result is a manifest whose
    #    coverage starts from this run. Stage 3 treats a module with no entry as
    #    'missing' and reprovisions it, which is the documented one-time
    #    migration for mast01-04.
    if ($null -ne $Previous -and $Previous.PSObject.Properties.Match('modules').Count) {
        foreach ($p in $Previous.modules.PSObject.Properties) {
            $modules[$p.Name] = $p.Value
        }
    }

    # 2. Overwrite the entries for modules this run actually touched.
    $buildState = $null
    if ($BuildData.PSObject.Properties.Match('module_state').Count) {
        $buildState = $BuildData.module_state
    }

    foreach ($name in $Outcomes.Keys) {
        $version = ''
        $hash = ''
        if ($null -ne $buildState -and $buildState.PSObject.Properties.Match($name).Count) {
            $entry = $buildState.$name
            if ($entry.PSObject.Properties.Match('version').Count) { $version = [string]$entry.version }
            if ($entry.PSObject.Properties.Match('hash').Count)    { $hash    = [string]$entry.hash }
        }
        $modules[$name] = [ordered]@{
            version      = $version
            hash         = $hash
            provide      = [string]$Outcomes[$name]['provide']
            verify       = [string]$Outcomes[$name]['verify']
            installed_at = $InstalledAt
        }
    }

    # 3. fully_provisioned: every module the BUILD declares is present, matches
    #    the build hash, installed cleanly, and did not fail its verify. A module
    #    with no verify command ('none') does not disqualify the unit -- absence
    #    of a check is not a failed check.
    $fully = $true
    $buildModules = @()
    if ($BuildData.PSObject.Properties.Match('modules').Count) {
        $buildModules = @($BuildData.modules | ForEach-Object { [string]$_ })
    }
    if ($buildModules.Count -eq 0) { $fully = $false }
    foreach ($name in $buildModules) {
        if (-not $modules.Contains($name)) { $fully = $false; break }
        $m = $modules[$name]
        $mHash    = [string](Get-MastEntryField -Entry $m -Field 'hash')
        $mProvide = [string](Get-MastEntryField -Entry $m -Field 'provide')
        $mVerify  = [string](Get-MastEntryField -Entry $m -Field 'verify')
        $wantHash = ''
        if ($null -ne $buildState -and $buildState.PSObject.Properties.Match($name).Count) {
            $wantHash = [string]$buildState.$name.hash
        }
        if (-not $mHash -or $mHash -ne $wantHash) { $fully = $false; break }
        if ($mProvide -ne $script:MastModulePass)  { $fully = $false; break }
        if ($mVerify  -eq $script:MastModuleFail)  { $fully = $false; break }
    }

    $out = [ordered]@{
        installed_at      = $InstalledAt
        fully_provisioned = $fully
        modules           = $modules
    }

    # Carry the build's identity fields for reporting.
    foreach ($f in @('built_at', 'git_sha', 'hostname')) {
        if ($BuildData.PSObject.Properties.Match($f).Count) { $out[$f] = $BuildData.$f }
    }

    # The aggregate payload_hash is the EXISTING fast path: check-and-provision.ps1
    # and server/prov/driver.py compare it to decide "nothing changed, skip".
    # Publishing it after a partial run would assert the whole payload is
    # installed when it is not, and the loop would skip a unit that still needs
    # work. So it is written ONLY when fully_provisioned -- a partial run leaves
    # it absent, the fast path misses, and the per-module comparison (Stage 3)
    # decides what to do. Fail safe, not fail quiet.
    if ($fully -and $BuildData.PSObject.Properties.Match('payload_hash').Count) {
        $out['payload_hash'] = $BuildData.payload_hash
    }

    return [pscustomobject]$out
}

# Read a field from an entry that may be either a PSCustomObject (parsed from
# JSON, i.e. carried forward from a previous run) or an ordered hashtable (built
# fresh in this run). Both shapes coexist in the merged map by construction.
function Get-MastEntryField {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$Field)

    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains($Field)) { return $Entry[$Field] }
        return $null
    }
    if ($Entry.PSObject.Properties.Match($Field).Count) { return $Entry.$Field }
    return $null
}
