#requires -Version 5.1
<#
  Verify the outcome of provide-mast.ps1 against the mast-clone layout.

  Content-aware, not presence-only (per-module-tracking resolution rule 2): a
  clone sitting on a stale commit, or a venv resolved months ago against
  different package versions, passes every Test-Path in a presence check while
  being exactly the drift this epic exists to catch. So this compares:

    - each clone's HEAD against the branch its remote currently points at, and
    - the venv's installed distributions against each repo's PINNED
      requirements.txt. Upstream pinned everything exactly in Jul-Aug 2026,
      which is what makes this comparison well defined at all -- against the
      old '>=' constraints there was no single correct answer to compare to.

  A DIRTY working tree is a failure, not a warning: mast-clone declines to
  fast-forward one, so without this the unit silently stops receiving updates
  while still reporting healthy.

  Exit 0 = pass. Exit 1 = fail, with the reasons in the verify log.
#>
[CmdletBinding()]
param(
    [string]${Top} = 'C:\MAST\src',
    # Folder names mast-clone creates for the 'unit' role, injected from
    # module.json so the expectation is build-time data rather than a second
    # copy of the role table living in this script.
    [string]${Expect} = 'common,unit,claude'
)

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${currencyDot} = Join-Path ${PSScriptRoot} 'mast-git-currency.ps1'
if (-not (Test-Path ${currencyDot})) { ${currencyDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-git-currency.ps1' }
if (-not (Test-Path ${currencyDot})) { throw "mast-git-currency.ps1 not found at ${currencyDot}" }
. ${currencyDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts probe optional state
${verifyLog} = Get-MastVerifyLog -Module 'mast'
${smokeFile} = Get-MastSmokeMarker -Module 'mast'

function W {
    param([string]${Line})
    Add-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), ${Line})
}
Set-Content -LiteralPath ${verifyLog} -Encoding UTF8 `
    -Value ("[{0}] verify-mast.ps1 started (top={1})" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ${Top})

${issues} = New-Object 'System.Collections.Generic.List[string]'
# Checks that could not be RUN, as opposed to checks that failed. Kept apart all
# the way to the exit code: folding them into ${issues} would report a network
# condition as unit drift, and folding them into silence is what #177 was.
${unverifiable} = New-Object 'System.Collections.Generic.List[string]'
${expected} = @(${Expect}.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# clone-manifest.json is the fallback evidence when origin cannot be reached: it
# records, per repo, whether mast-clone verified that SHA against origin and when
# (#176). Read once, before the loop, so an unreadable sidecar degrades every
# repo's fallback identically instead of throwing mid-check.
${cloneRepos} = @{}
${cloneRevs} = @{}
${cloneWrittenAt} = ''
${cloneManifestPath} = Join-Path ${Top} 'clone-manifest.json'
if (Test-Path -LiteralPath ${cloneManifestPath}) {
    try {
        ${cm} = Get-Content -LiteralPath ${cloneManifestPath} -Raw | ConvertFrom-Json
        if (${cm}.PSObject.Properties.Match('written_at').Count) { ${cloneWrittenAt} = [string]${cm}.written_at }
        foreach (${r} in @(${cm}.repos)) {
            # $null, not $false, when the key is absent -- 'never recorded' and
            # 'recorded as unverified' are different findings and the verdict
            # table words them differently.
            ${ok} = $null
            if (${r}.PSObject.Properties.Match('fetch_ok').Count) { ${ok} = [bool]${r}.fetch_ok }
            ${cloneRepos}[[string]${r}.dir] = ${ok}
            ${cloneRevs}[[string]${r}.dir] = [string]${r}.rev
        }
    }
    catch {
        W ("clone-manifest.json unreadable, no fallback evidence: {0}" -f $_.Exception.Message)
    }
}

function Resolve-GitExe {
    foreach (${c} in @('C:\Program Files\Git\cmd\git.exe', 'C:\Program Files\Git\bin\git.exe')) {
        if (Test-Path -LiteralPath ${c}) { return ${c} }
    }
    ${g} = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (${g}) { return ${g}.Source }
    return $null
}

if (-not (Test-Path -LiteralPath ${Top})) {
    [void]${issues}.Add("source tree missing: ${Top}")
}

${venvPython} = Join-Path ${Top} '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath ${venvPython})) {
    [void]${issues}.Add("venv interpreter missing: ${venvPython}")
}

# 'common' must be an importable package: its repo root carries __init__.py and
# the whole no-submodule scheme rests on that. Landing on the abandoned 2-commit
# 'main' stub produces a checkout without it, and every 'from common.X import'
# on the unit then fails at service start.
if ((Test-Path -LiteralPath (Join-Path ${Top} 'common')) -and
    -not (Test-Path -LiteralPath (Join-Path ${Top} 'common\__init__.py'))) {
    [void]${issues}.Add("common\__init__.py missing -- 'common' is not an importable package (wrong branch?)")
}

# mast.pth is what puts <Top> on sys.path for the NSSM services, which inherit
# no shell environment. Without it the unit imports nothing.
${pth} = Join-Path ${Top} '.venv\Lib\site-packages\mast.pth'
if (-not (Test-Path -LiteralPath ${pth})) {
    [void]${issues}.Add("mast.pth missing at ${pth} -- <Top> will not be on sys.path")
}

${gitExe} = Resolve-GitExe
foreach (${d} in ${expected}) {
    ${repoDir} = Join-Path ${Top} ${d}
    if (-not (Test-Path -LiteralPath ${repoDir})) {
        [void]${issues}.Add("clone missing: ${repoDir}")
        continue
    }
    if (-not (Test-Path -LiteralPath (Join-Path ${repoDir} '.git'))) {
        [void]${issues}.Add("incomplete clone (no .git): ${repoDir}")
        continue
    }
    if (-not ${gitExe}) { continue }

    # Dirty tree: mast-clone will not fast-forward it, so the clone is frozen.
    ${status} = & ${gitExe} -C ${repoDir} status --porcelain 2>$null
    if (${status}) {
        [void]${issues}.Add(("working tree dirty, updates are being skipped: {0}" -f ${repoDir}))
    }

    # Current? ASK THE REMOTE. Deliberately not 'rev-parse @{u}', which reads the
    # remote-TRACKING ref -- a local pointer only a fetch updates, so after a failed
    # fetch it holds the commit HEAD is already on and a stale clone reads as
    # current (#177, and the run in #176 where this logged 'current' on three
    # clones that had fetched nothing).
    #
    # ls-remote, not fetch: it queries origin and updates NO local ref, so this
    # stays a read-only check and one verify pass cannot change what the next one
    # would compare against.
    #
    # No proxy is configured here on purpose. A provisioned unit carries the
    # machine-scope http_proxy/https_proxy the proxy provider sets at order 100,
    # which this process inherits -- that is the unit's own posture, and imposing
    # a different one would test a route the unit does not use. (Measured on the
    # dev VM: ls-remote returns in ~1s with nothing configured at all.)
    ${head} = (& ${gitExe} -C ${repoDir} rev-parse HEAD 2>$null | Select-Object -First 1)

    # What to ask origin FOR. A branch checkout carries its upstream name; a
    # pinned checkout is detached and has none, so the sidecar's rev is used.
    # Without this the pinned case got no comparison at all -- dormant today
    # (no row in mast-repos.tsv pins a rev) and live the moment #75 lands one.
    ${remoteSha} = ''
    ${upstreamName} = (& ${gitExe} -C ${repoDir} rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null | Select-Object -First 1)
    ${lsArgs} = $null
    if (${upstreamName} -and ${upstreamName} -match '^[^/]+/(.+)$') {
        ${lsArgs} = @('ls-remote', '--heads', 'origin', ('refs/heads/{0}' -f ${Matches}[1]))
    }
    elseif (${cloneRevs}.ContainsKey(${d}) -and ${cloneRevs}[${d}]) {
        ${lsArgs} = @('ls-remote', '--tags', 'origin', ('refs/tags/{0}' -f ${cloneRevs}[${d}]))
    }
    if (${lsArgs}) {
        # Collect, THEN read $LASTEXITCODE. 'Select-Object -First 1' in the same
        # pipeline stops the upstream command early, which leaves $LASTEXITCODE
        # reflecting that termination rather than git's own result.
        ${lsOut} = @(& ${gitExe} -C ${repoDir} @lsArgs 2>$null)
        ${lsCode} = $LASTEXITCODE
        if (${lsCode} -eq 0 -and ${lsOut}.Count -gt 0 -and ${lsOut}[0]) {
            ${remoteSha} = ([string]${lsOut}[0]).Split(@("`t", ' '), [StringSplitOptions]::RemoveEmptyEntries)[0]
        } else {
            W ("{0}: ls-remote could not reach origin (exit {1})" -f ${d}, ${lsCode})
        }
    }
    else {
        W ("{0}: no upstream branch and no pinned rev -- nothing to ask origin for" -f ${d})
    }

    ${fetchOk} = $null
    if (${cloneRepos}.ContainsKey(${d})) { ${fetchOk} = ${cloneRepos}[${d}] }
    ${verdict} = Get-MastCurrencyVerdict -Dir ${d} -HeadSha ${head} -RemoteSha ${remoteSha} `
                    -FetchOk ${fetchOk} -VerifiedAt ${cloneWrittenAt}
    W ${verdict}.Message
    if (${verdict}.State -eq ${MastCurrencyUnverifiable}) {
        [void]${unverifiable}.Add(${verdict}.Message)
    }
    elseif (${verdict}.State -ne ${MastCurrencyCurrent}) {
        [void]${issues}.Add(${verdict}.Message)
    }
}

# Dependency currency: every pinned requirement installed at its pin. This is
# the check a presence-only verify could not make.
#
# Enumerated with UV, not 'python -m pip freeze'. The venv is built by uv, and
# pip freeze does not faithfully report it: on the first real VM cycle
# (2026-08-03) freeze listed 76 packages and omitted docstring-parser, while
# 'uv pip list' showed 80 including it and site-packages\docstring_parser was
# on disk -- i.e. the check produced a phantom "not installed" failure. Ask the
# environment with the tool that built it. pip freeze remains the fallback for a
# unit where the vendored uv is absent, which is better than no check at all.
function Get-InstalledPins {
    param([string]$UvExe, [string]$VenvPython)
    $out = $null
    if ($UvExe -and (Test-Path -LiteralPath $UvExe)) {
        $out = & $UvExe pip freeze --python $VenvPython 2>$null
    }
    if (-not $out) { $out = & $VenvPython -m pip freeze 2>$null }
    $map = @{}
    foreach ($line in $out) {
        if ($line -match '^([^=<>!~ ]+)==(.+)$') {
            $map[(Get-NormalizedDistName $Matches[1])] = $Matches[2].Trim()
        }
    }
    return $map
}

# PEP 503: distribution names are case-insensitive and '-', '_' and '.' are
# equivalent, so docstring-parser and docstring_parser are the same package.
# Compare normalized on both sides or a spelling difference reads as missing.
function Get-NormalizedDistName {
    param([string]$Name)
    return ((${Name}.Trim().ToLowerInvariant()) -replace '[-_.]+', '-')
}

if (Test-Path -LiteralPath ${venvPython}) {
    ${frozen} = Get-InstalledPins -UvExe (Join-Path ${Top} '.tools\uv.exe') -VenvPython ${venvPython}
    if (${frozen}.Count -eq 0) {
        [void]${issues}.Add('neither uv nor pip could enumerate the venv -- unusable?')
    } else {
        foreach (${d} in ${expected}) {
            ${req} = Join-Path (Join-Path ${Top} ${d}) 'requirements.txt'
            if (-not (Test-Path -LiteralPath ${req})) { continue }
            foreach (${line} in (Get-Content -LiteralPath ${req} -ErrorAction SilentlyContinue)) {
                ${t} = ${line}.Trim()
                if (-not ${t} -or ${t}.StartsWith('#')) { continue }
                # Only '==' pins are checkable; anything looser has no single
                # correct answer and is skipped rather than guessed at.
                if (${t} -notmatch '^([A-Za-z0-9._-]+)==([^;#\s]+)') { continue }
                ${name} = Get-NormalizedDistName ${Matches}[1]
                ${want} = ${Matches}[2].Trim()
                if (-not ${frozen}.ContainsKey(${name})) {
                    [void]${issues}.Add(("{0}: {1}=={2} not installed" -f ${d}, ${name}, ${want}))
                } elseif (${frozen}[${name}] -ne ${want}) {
                    [void]${issues}.Add(("{0}: {1} is {2}, pinned {3}" -f ${d}, ${name}, ${frozen}[${name}], ${want}))
                }
            }
        }
    }
}

if (${issues}.Count -gt 0) {
    (${issues} -join [Environment]::NewLine) | Out-File -FilePath ${verifyLog} -Append -Encoding UTF8
    if (Test-Path -LiteralPath ${smokeFile}) {
        Remove-Item -LiteralPath ${smokeFile} -Force -ErrorAction SilentlyContinue
    }
    Write-Host ("mast-verify FAILED: {0}" -f (${issues} -join '; '))
    exit 1
}

# Exit 2: every check that could run passed, and at least one could not run. A
# THIRD state, not a severity between 0 and 1 -- run-verify-only.ps1 records it as
# 'unverifiable' rather than folding it into pass or fail, and the fleet report
# renders it as its own thing. Reporting it as a pass is what #177 was; reporting
# it as a failure would put a unit in the red for a network condition.
#
# The smoke marker is still written: the local checks did pass, and the marker's
# meaning ('this module's verify ran and found nothing wrong') is unchanged.
if (${unverifiable}.Count -gt 0) {
    (${unverifiable} -join [Environment]::NewLine) | Out-File -FilePath ${verifyLog} -Append -Encoding UTF8
    Set-Content -Path ${smokeFile} -Value 'mast_ok' -Encoding UTF8
    W ("mast verify UNVERIFIABLE: {0} of {1} clone(s) could not be checked against origin" -f ${unverifiable}.Count, ${expected}.Count)
    Write-Host ("mast-verify UNVERIFIABLE: {0}" -f (${unverifiable} -join '; '))
    exit (Get-MastVerifyExitCode -IssueCount ${issues}.Count -UnverifiableCount ${unverifiable}.Count)
}

Set-Content -Path ${smokeFile} -Value 'mast_ok' -Encoding UTF8
W ("mast verify ok: {0} clone(s) current under {1}" -f ${expected}.Count, ${Top})
Write-Host 'mast-verify OK'
exit 0
