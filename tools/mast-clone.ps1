#Requires -Version 5.1
<#
.SYNOPSIS
  Populate a top folder with the MAST repos for a given role.

.DESCRIPTION
  Creates a flat hierarchy under -Top:

    <Top>\
      common\    MAST_common          (the 'common' Python package)
      unit\      MAST_unit.2024-12-12
      control\   MAST_control
      gui\       MAST_gui
      spec\      MAST_spec
      claude\    mast-claude-config

  Which folders appear is driven by -Role and the manifest mast-repos.tsv,
  which is the single source of truth shared with tools/mast-clone.sh.

  WHY THE LAYOUT WORKS: MAST_common's repo root carries an __init__.py, so the
  repo root *is* the 'common' package. Cloning it into a folder literally named
  'common' and putting <Top> on sys.path makes every existing
  'from common.X import ...' resolve unchanged -- no source edits, and no
  submodule. The venv at <Top>\.venv is how sys.path gets set at runtime.

  Used two ways:
    1. At provisioning time, to fetch the unit repos onto a unit machine.
    2. Casually, to clone a development environment anywhere.

  Idempotent: re-running fetches existing clones rather than re-cloning, and
  never merges over local work unless -Update is given (and even then only
  fast-forward, only on a clean tree).

.PARAMETER Top
  Top folder to populate. Created if missing. Required.

.PARAMETER Role
  One or more of: unit, control, spec, all. Required. 'all' pulls every repo.
  Roles union, so -Role unit,spec is valid.

.PARAMETER Transport
  'https' (default) or 'ssh'. HTTPS needs no key material and works on a freshly
  provisioned unit. SSH needs a key AND, on the Weizmann network, an ssh config
  tunnelling github.com to ssh.github.com:443, because port 22 is blocked -- a
  fresh unit has neither, which is why HTTPS is the default.


.PARAMETER DirectHttp
  Reach the internet directly, with no proxy. For networks that do not go
  through the Weizmann bcproxy (off-campus, home, open egress). Without it,
  outbound HTTPS goes via an exported HTTPS_PROXY if there is one, else bcproxy.

.PARAMETER Branch
  Hashtable overriding the manifest branch for a folder, e.g.
  -Branch @{ unit = 'acquisition_tuning' }. The default comes from
  mast-repos.tsv, NOT from the remote's default HEAD: MAST_common and
  MAST_control both have an abandoned 2-commit 'main' as their GitHub default
  while real work lives on 'master'. See mast-repos.tsv for the full note.

.PARAMETER Update
  For folders that already exist, fast-forward them. Without this they are only
  fetched.

.PARAMETER DryRun
  Print what would happen; change nothing.

.EXAMPLE
  .\mast-clone.ps1 -Top C:\MAST\src -Role unit -Transport ssh

.EXAMPLE
  .\mast-clone.ps1 -Top D:\dev\mast -Role all -Update

.EXAMPLE
  # On a network that does not go through the Weizmann proxy:
  .\mast-clone.ps1 -Top C:\MAST\src -Role unit -DirectHttp

.NOTES
  Companion: tools/mast-clone.sh (same manifest, same layout, for Linux).
  ASCII-only and Windows PowerShell 5.1 compatible per repo CLAUDE.md.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Top,

    [Parameter(Mandatory = $true)]
    [string[]] $Role,

    [ValidateSet('ssh', 'https')]
    [string] $Transport = 'https',

    [hashtable] $Branch = @{},

    [switch] $DirectHttp,

    [switch] $Update,

    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Org = 'The-MAST-project'
$Manifest = Join-Path $PSScriptRoot 'mast-repos.tsv'

function Write-Info { param([string] $Message) Write-Host "[mast-clone] $Message" }
function Write-Warn { param([string] $Message) Write-Warning "[mast-clone] $Message" }

function Invoke-Native {
    # Run a native exe, stream its output to the host, return its exit code.
    #
    # WHY THIS EXISTS: with $ErrorActionPreference = 'Stop' (set at the top of
    # this script), Windows PowerShell 5.1 wraps every stderr line of a native
    # command redirected with 2>&1 into an ErrorRecord and THROWS on the first
    # one. git writes ordinary progress ("Cloning into '...'") to stderr, so a
    # perfectly successful clone aborts the script. PowerShell 7 does not
    # behave this way, so this only ever bites on the 5.1 target -- which is
    # exactly where provisioning runs. Dropping to 'Continue' for the duration
    # of the call is the documented workaround; $LASTEXITCODE still carries the
    # real success/failure.
    param([string] $Exe, [string[]] $NativeArgs)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @NativeArgs 2>&1 | Out-Host
        return $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $saved }
}

function Invoke-Git {
    # Echo-and-execute, honouring -DryRun. Returns $true on success.
    #
    # git's own output MUST go straight to the host via Out-Host. A bare
    # '& git ...' emits to the success stream, and a PowerShell function
    # returns *everything* on that stream -- so the caller would receive
    # git's stdout lines plus the boolean, i.e. a non-empty array, which is
    # always truthy. Every failure check would then silently pass.
    param([string[]] $GitArgs)
    if ($DryRun) {
        Write-Host ("       would run: git " + ($GitArgs -join ' '))
        return $true
    }
    $code = Invoke-Native -Exe 'git' -NativeArgs $GitArgs
    if ($code -ne 0) { return $false }
    return $true
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git is not on PATH'
}

# Never let git stop to ask for credentials. Provisioning runs unattended (WinRM
# task, SSH session, scheduled task), where there is no console to prompt on.
# Without this, a private repo sends git through Git Credential Manager, which
# fails to persist to 'wincredman' in a non-interactive session, then tries to
# open a tty, and only then reports a confusing "could not read Username".
# With this set, a missing credential fails immediately and says so.
$env:GIT_TERMINAL_PROMPT = '0'

# Everything this script fetches is external: github.com for the clones and for
# the uv bootstrap download, PyPI for the venv. Direct egress from the Weizmann
# network TIMES OUT rather than being refused, so without a proxy the first
# clone hangs for a couple of minutes before failing -- a slow, confusing
# failure that reads as a hung script rather than a network policy.
#
# Environment variables, NOT 'git config http.proxy': one setting covers all
# three consumers (git, the uv download, and uv itself), and nothing is left
# behind in a repo config or the user's global gitconfig afterwards.
#
# Set regardless of -Transport. Even when the clones go over SSH -- which
# ignores the http proxy -- the uv download and 'uv pip install' are still
# HTTPS and still need it.
#
# -DirectHttp is for networks with no proxy at all -- off-campus, home, or a
# site whose egress is open. Otherwise an already-exported HTTPS_PROXY wins
# (point somewhere else without touching the script), and failing that the
# Weizmann bcproxy is used.
$DefaultProxy   = 'http://bcproxy.weizmann.ac.il:8080'
# Fleet-internal destinations must NOT be sent to the proxy; it cannot reach
# 10.23.x and the request dies there rather than going direct.
$DefaultNoProxy = 'localhost,127.0.0.1,10.23.0.0/16'

if ($DirectHttp) {
    # Clear, do not merely skip. An HTTPS_PROXY inherited from the caller's
    # environment (a machine-wide setting, a scheduled task, an outer script)
    # would otherwise still be honoured by git and uv, and -DirectHttp would
    # quietly do nothing -- on a network where that proxy is unreachable, that
    # is a hang.
    $env:HTTP_PROXY  = $null
    $env:HTTPS_PROXY = $null
    $env:http_proxy  = $null
    $env:https_proxy = $null
    $EffectiveProxy = 'direct (-DirectHttp)'
}
else {
    $EffectiveProxy = $DefaultProxy
    if (-not [string]::IsNullOrWhiteSpace($env:HTTPS_PROXY)) { $EffectiveProxy = $env:HTTPS_PROXY }

    $env:HTTP_PROXY  = $EffectiveProxy
    $env:HTTPS_PROXY = $EffectiveProxy
    $env:http_proxy  = $EffectiveProxy
    $env:https_proxy = $EffectiveProxy

    # Keep an operator-supplied NO_PROXY if there is one.
    if ([string]::IsNullOrWhiteSpace($env:NO_PROXY)) {
        $env:NO_PROXY = $DefaultNoProxy
        $env:no_proxy = $DefaultNoProxy
    }
}

if (-not (Test-Path -LiteralPath $Manifest)) {
    throw "manifest not found: $Manifest"
}

# --- load the manifest ----------------------------------------------------
$rows = @()
foreach ($line in (Get-Content -LiteralPath $Manifest)) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0) { continue }
    if ($trimmed.StartsWith('#')) { continue }
    $parts = $line -split "`t"
    if ($parts.Count -lt 4) { continue }
    # 'rev' is an OPTIONAL 5th column, so a 4-column manifest still parses -- see
    # mast-repos.tsv. Empty means "track the branch".
    $rev = ''
    if ($parts.Count -ge 5) { $rev = $parts[4].Trim() }
    $rows += [pscustomobject]@{
        Dir    = $parts[0].Trim()
        Repo   = $parts[1].Trim()
        Roles  = ($parts[2].Trim() -split ',')
        Branch = $parts[3].Trim()
        Rev    = $rev
    }
}
if ($rows.Count -eq 0) { throw "manifest '$Manifest' yielded no rows" }

# Pinned tool versions live in the manifest too, as '#!<key><tab><value>', so
# the ps1 and sh halves cannot drift. They start with '#', so the row loop above
# already skipped them.
$UvVersion = ''
foreach ($line in (Get-Content -LiteralPath $Manifest)) {
    if ($line -match '^#!uv-version\s+(\S+)') { $UvVersion = $Matches[1]; break }
}

# Validate roles against the manifest so a typo fails loudly rather than
# silently cloning nothing.
$knownRoles = @($rows | ForEach-Object { $_.Roles } | Sort-Object -Unique)
$selected = @()
foreach ($r in $Role) {
    foreach ($one in ($r -split ',')) {
        $one = $one.Trim()
        if ($one.Length -eq 0) { continue }
        if ($one -ne 'all' -and $knownRoles -notcontains $one) {
            throw ("unknown role '{0}'; known roles: all {1}" -f $one, ($knownRoles -join ' '))
        }
        $selected += $one
    }
}
if ($selected.Count -eq 0) { throw '-Role resolved to nothing' }
$wantsAll = ($selected -contains 'all')

Write-Info ("top       : {0}" -f $Top)
Write-Info ("roles     : {0}" -f ($selected -join ' '))
Write-Info ("transport : {0}" -f $Transport)
Write-Info ("proxy     : {0}" -f $EffectiveProxy)
if ($DryRun) { Write-Info 'DRY RUN -- nothing will be modified' }

if (-not $DryRun) {
    $null = New-Item -ItemType Directory -Path $Top -Force
}
$topAbs = $Top
if (Test-Path -LiteralPath $Top) {
    $topAbs = (Resolve-Path -LiteralPath $Top).Path
}

# --- clone / refresh ------------------------------------------------------
$cloned = @()
$provenance = @()
foreach ($row in $rows) {
    $wanted = $wantsAll
    if (-not $wanted) {
        foreach ($rr in $row.Roles) {
            if ($selected -contains $rr) { $wanted = $true; break }
        }
    }
    if (-not $wanted) { continue }

    $dest = Join-Path $topAbs $row.Dir
    if ($Transport -eq 'ssh') {
        $url = "git@github.com:$Org/$($row.Repo).git"
    }
    else {
        $url = "https://github.com/$Org/$($row.Repo).git"
    }

    # Manifest branch is the default; -Branch overrides it. Never fall back to
    # the remote default HEAD -- for common and control that is an abandoned
    # 2-commit stub (see mast-repos.tsv).
    $pin = $row.Branch
    $rev = $row.Rev
    if ($Branch.ContainsKey($row.Dir)) {
        $pin = [string] $Branch[$row.Dir]
        # An explicit override is a developer saying "follow this branch"; honouring
        # the pin as well would silently ignore them. Loud, because it means this
        # checkout is deliberately NOT the pinned revision.
        if ($rev) {
            Write-Warn ("{0}: -Branch override '{1}' displaces the pinned rev '{2}'" -f $row.Dir, $pin, $rev)
            $rev = ''
        }
    }
    if (-not $pin) { throw ("{0}: no branch in manifest and no -Branch override" -f $row.Dir) }

    $cloned += $row.Dir
    $provenance += [pscustomobject]@{
        dir    = $row.Dir
        repo   = $row.Repo
        branch = $pin
        rev    = $rev          # as REQUESTED (tag/SHA), '' when tracking the branch
    }

    if (Test-Path -LiteralPath (Join-Path $dest '.git')) {
        # Idempotent re-run. Never merge implicitly -- local work is sacred.
        $actual = ''
        & git -C $dest remote get-url origin 2>$null | ForEach-Object { $actual = $_ }
        if ($actual -notlike "*$($row.Repo)*") {
            Write-Warn ("{0}: origin is '{1}', expected a {2} remote -- skipping" -f $row.Dir, $actual, $row.Repo)
            continue
        }
        Write-Info ("{0}: exists, fetching" -f $row.Dir)
        $null = Invoke-Git @('-C', $dest, 'fetch', '--prune', 'origin')
        if ($Update) {
            $dirty = $false
            if (-not $DryRun) {
                $status = & git -C $dest status --porcelain
                if ($status) { $dirty = $true }
            }
            if ($dirty) {
                Write-Warn ("{0}: working tree dirty -- not moving" -f $row.Dir)
            }
            elseif ($rev) {
                # Pinned: re-assert the revision. Deliberately NOT a fast-forward --
                # 'merge --ff-only @{u}' is a branch operation and would defeat the
                # pin. --force on the tag fetch so a legitimately moved tag is
                # picked up; the resolved SHA below records what it moved to.
                Write-Info ("{0}: pinned, checking out {1}" -f $row.Dir, $rev)
                $null = Invoke-Git @('-C', $dest, 'fetch', '--tags', '--force', 'origin')
                if (-not (Invoke-Git @('-C', $dest, 'checkout', '--detach', $rev))) {
                    throw ("{0}: cannot check out pinned rev '{1}'" -f $row.Dir, $rev)
                }
            }
            else {
                Write-Info ("{0}: fast-forwarding" -f $row.Dir)
                if (-not (Invoke-Git @('-C', $dest, 'merge', '--ff-only', '@{u}'))) {
                    Write-Warn ("{0}: not a fast-forward, left alone" -f $row.Dir)
                }
            }
        }
    }
    elseif (Test-Path -LiteralPath $dest) {
        Write-Warn ("{0}: '{1}' exists but is not a git clone -- skipping" -f $row.Dir, $dest)
        continue
    }
    else {
        Write-Info ("{0}: cloning {1} (branch {2}{3})" -f $row.Dir, $row.Repo, $pin,
                    $(if ($rev) { ", pinned at $rev" } else { '' }))
        if (-not (Invoke-Git @('clone', '--branch', $pin, $url, $dest))) {
            throw ("{0}: clone failed" -f $row.Dir)
        }
        if ($rev) {
            # Clone the branch first rather than 'clone --branch <tag>': it leaves
            # the branch ref present, which the -Branch override and the wrong-branch
            # diagnostic below both rely on.
            $null = Invoke-Git @('-C', $dest, 'fetch', '--tags', '--force', 'origin')
            if (-not (Invoke-Git @('-C', $dest, 'checkout', '--detach', $rev))) {
                throw ("{0}: cannot check out pinned rev '{1}'" -f $row.Dir, $rev)
            }
        }
    }
}

# --- disarm the vestigial 'common' submodule ------------------------------
#
# control, gui, spec and unit still declare MAST_common as a submodule, so each
# clone carries a committed gitlink and an empty <repo>\common (or
# <repo>\src\common) mount point. It is inert here -- <Top>\common has an
# __init__.py and so is a regular package, which beats an empty directory
# (a mere namespace portion) wherever it appears on sys.path.
#
# The real hazard is someone running 'git submodule update --init' in one of
# these clones: that materialises a SECOND common, stale the moment <Top>\common
# moves. 'update = none' makes --init skip it. Note that
# submodule.<name>.active = false is NOT enough -- --init overrides it.
#
# Local config only, so the working tree stays clean and -Update keeps working.
# Removing the gitlink instead would leave every clone permanently dirty.
if (-not $DryRun) {
    foreach ($d in $cloned) {
        if ($d -eq 'common') { continue }
        $gm = Join-Path $topAbs "$d\.gitmodules"
        if ((Test-Path -LiteralPath $gm) -and
            (Select-String -LiteralPath $gm -Pattern 'submodule "common"' -Quiet)) {
            Invoke-Native -Exe 'git' -NativeArgs @('-C', (Join-Path $topAbs $d),
                'config', '--local', 'submodule.common.update', 'none') | Out-Null
            Write-Info "${d}: pinned submodule.common.update=none (vestigial submodule left unpopulated)"
        }
    }
}

# --- record what was actually deployed -------------------------------------
#
# A pin says what was ASKED FOR; this says what landed. Both matter: a tag can be
# force-moved upstream, and an unpinned repo resolves to whatever the branch head
# was at the moment THIS clone ran -- which is exactly how three units ended up on
# two different MAST_common commits from one fleet run (#75). The unit-side
# installed-manifest.json folds this in, so a unit can be asked what it is running
# without the operator cloning anything.
$provFile = Join-Path $topAbs 'clone-manifest.json'
if (-not $DryRun) {
    $repoRecords = @()
    foreach ($pr in $provenance) {
        $sha = ''
        $head = ''
        $d = Join-Path $topAbs $pr.dir
        if (Test-Path -LiteralPath (Join-Path $d '.git')) {
            & git -C $d rev-parse HEAD 2>$null | ForEach-Object { $sha = $_.Trim() }
            & git -C $d rev-parse --abbrev-ref HEAD 2>$null | ForEach-Object { $head = $_.Trim() }
        }
        $repoRecords += [pscustomobject]@{
            dir          = $pr.dir
            repo         = $pr.repo
            branch       = $pr.branch
            rev          = $pr.rev
            resolved_sha = $sha
            # 'HEAD' means detached, which is what a pinned checkout looks like.
            head         = $head
        }
    }
    $provDoc = [pscustomobject]@{
        written_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        manifest   = (Split-Path -Leaf $Manifest)
        repos      = $repoRecords
    }
    # UTF8 without BOM: the readers are Python and PowerShell, and a BOM trips
    # non-PowerShell JSON parsers (see the driver's BOM-tolerant reads).
    [IO.File]::WriteAllText($provFile, ($provDoc | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    Write-Info ("wrote {0}" -f $provFile)
    foreach ($r in $repoRecords) {
        Write-Info ("  {0}: {1} {2}{3}" -f $r.dir, $r.branch,
                    $(if ($r.rev) { "pinned $($r.rev) -> " } else { '' }),
                    $(if ($r.resolved_sha) { $r.resolved_sha.Substring(0, [Math]::Min(7, $r.resolved_sha.Length)) } else { '?' }))
    }
}

# --- sanity check: the file the whole scheme rests on ---------------------
#
# MAST_common's root __init__.py is what makes 'common' an importable package.
# If it is missing, the clone landed on the wrong branch (the 2-commit 'main'
# stub) and every 'from common.X import ...' in the fleet will fail. Catch it
# here, at provisioning time, instead of at service start on a dark unit.
$commonDir = Join-Path $topAbs 'common'
if ((-not $DryRun) -and (Test-Path -LiteralPath $commonDir) -and
    (-not (Test-Path -LiteralPath (Join-Path $commonDir '__init__.py')))) {
    $onBranch = & git -C $commonDir rev-parse --abbrev-ref HEAD 2>$null
    $atSha = & git -C $commonDir rev-parse --short HEAD 2>$null
    # 'HEAD' for the branch means a detached checkout, i.e. a pinned rev -- in which
    # case the pin is the thing to look at, not the branch.
    throw ("common\__init__.py is missing -- 'common' is not an importable package. " +
           "The checkout landed somewhere without it. HEAD: {0} ({1}). " +
           "Expected the branch, or the rev, pinned in mast-repos.tsv." -f $onBranch, $atSha)
}

# --- venv creation and population ------------------------------------------
#
# uv does both jobs: 'uv venv' creates, 'uv pip install' populates. It is
# required rather than optional -- falling back to python -m venv + pip would
# resolve a different dependency set than the one uv locks onto, so a fleet
# provisioned by two different paths would drift, which is the whole thing
# these scripts exist to prevent.
#
# Requirements are installed per cloned repo. MAST_common ships only
# requirements-dev.txt (no runtime deps of its own), so it contributes nothing
# here; unit/control/gui/spec each carry a pinned requirements.txt.

function Install-PinnedUv {
    # Pinned + checksum-verified, deliberately NOT 'irm ... | iex':
    #   - the pipe executes whatever the URL serves at that moment, unreviewed;
    #   - it installs "latest", so machines provisioned weeks apart get
    #     different resolvers and the fleet drifts.
    param([string] $Version, [string] $Dest)

    if (-not $Version) { throw "no '#!uv-version' directive in the manifest" }
    $asset = 'uv-x86_64-pc-windows-msvc.zip'
    $url   = "https://github.com/astral-sh/uv/releases/download/$Version/$asset"
    $tmp   = Join-Path ([System.IO.Path]::GetTempPath()) ("mast-uv-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Write-Info "bootstrapping uv $Version from $url"
        # TLS 1.2 is not the default in Windows PowerShell 5.1; GitHub requires it.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $zip = Join-Path $tmp $asset
        Invoke-WebRequest -Uri $url          -OutFile $zip          -UseBasicParsing
        Invoke-WebRequest -Uri "$url.sha256" -OutFile "$zip.sha256" -UseBasicParsing

        $expected = ((Get-Content -LiteralPath "$zip.sha256" -Raw).Trim() -split '\s+')[0]
        $actual   = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($expected -ne $actual) {
            throw ("uv checksum MISMATCH -- refusing to install.`n" +
                   "       expected: $expected`n" +
                   "       actual:   $actual")
        }
        Write-Info "uv checksum verified (sha256 $actual)"

        $unz = Join-Path $tmp 'unz'
        # Expand-Archive exists in 5.1 (PSCommunityExtensions ships in-box since 5.0).
        Expand-Archive -LiteralPath $zip -DestinationPath $unz -Force
        $bin = Get-ChildItem -Path $unz -Recurse -Filter 'uv.exe' | Select-Object -First 1
        if ($null -eq $bin) { throw 'uv.exe not found in the downloaded archive' }
        if (-not (Test-Path -LiteralPath $Dest)) {
            New-Item -ItemType Directory -Path $Dest -Force | Out-Null
        }
        Copy-Item -LiteralPath $bin.FullName -Destination (Join-Path $Dest 'uv.exe') -Force
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$Venv = Join-Path $topAbs '.venv'

# uv is acquired, never optional: the venv is always built, so a missing uv
# would simply mean a broken run. If the PINNED version is not already present
# we fetch it into <Top>\.tools -- checksum-verified, never "latest", never a
# remote script piped into a shell.
#
# The version is checked, not just the presence of a binary. The whole point of
# pinning uv in the manifest is that the resolver decides which dependency
# versions land in the venv, so accepting whatever uv happens to be on PATH
# would let two machines provisioned from the same manifest resolve differently
# -- exactly the drift the pin exists to prevent. A developer box with its own
# newer uv is the normal case, not an edge one. The same check covers
# <Top>\.tools\uv.exe, which may be left over from a run made before the
# manifest bumped the pin.
function Get-UvVersion {
    param([string] $Path)
    try {
        $out = & $Path --version 2>$null
        if ($LASTEXITCODE -ne 0) { return '' }
        # "uv 0.11.33 (abc1234 2026-01-01)" -> "0.11.33"
        $parts = ($out | Select-Object -First 1) -split '\s+'
        if ($parts.Count -ge 2) { return $parts[1] }
        return ''
    } catch {
        return ''
    }
}

$uvExe   = ''
$localUv = Join-Path $topAbs '.tools\uv.exe'

$uvCandidates = @()
$onPath = Get-Command uv -ErrorAction SilentlyContinue
if ($null -ne $onPath) { $uvCandidates += $onPath.Source }
$uvCandidates += $localUv

foreach ($cand in $uvCandidates) {
    if (-not (Test-Path -LiteralPath $cand)) { continue }
    $candVer = Get-UvVersion -Path $cand
    if ($candVer -eq $UvVersion) {
        $uvExe = $cand
        Write-Info ("uv        : {0} ({1}, pinned)" -f $uvExe, $UvVersion)
        break
    }
    $shown = $candVer
    if ([string]::IsNullOrWhiteSpace($shown)) { $shown = 'unknown' }
    Write-Info ("uv        : ignoring {0} ({1}), manifest pins {2}" -f $cand, $shown, $UvVersion)
}

if ([string]::IsNullOrWhiteSpace($uvExe)) {
    if ($DryRun) {
        Write-Host ("       would bootstrap uv {0} into {1}" -f $UvVersion, (Join-Path $topAbs '.tools'))
    }
    else {
        Install-PinnedUv -Version $UvVersion -Dest (Join-Path $topAbs '.tools')
    }
    $uvExe = $localUv
}

if (-not (Test-Path -LiteralPath $Venv)) {
    Write-Info "creating venv $Venv"
    if ($DryRun) {
        Write-Host ("       would run: {0} venv --seed {1}" -f $uvExe, $Venv)
    }
    else {
        $code = Invoke-Native -Exe $uvExe -NativeArgs @('venv', '--seed', $Venv)
        if ($code -ne 0) { throw 'uv venv failed' }
    }
}
else {
    Write-Info "venv $Venv exists, reusing"
}

# Interpreter path differs by platform: Windows Scripts\, POSIX bin/.
$vpy = ''
foreach ($cand in @((Join-Path $Venv 'Scripts\python.exe'), (Join-Path $Venv 'bin/python'))) {
    if (Test-Path -LiteralPath $cand) { $vpy = $cand; break }
}
if ($DryRun -and -not $vpy) { $vpy = Join-Path $Venv 'Scripts\python.exe' }
if (-not $vpy) { throw "no interpreter under '$Venv' after creation" }

# ONE resolve, not one per repo. A compound role (control = control + gui) puts
# several requirements files into a single venv, and those files can pin the
# same package differently. Installing them one after another would silently
# let the last file win, leaving a service running versions it was never tested
# against. Passing every -r in one invocation makes uv resolve them together and
# fail loudly on a contradiction, which is the only safe outcome: repos that
# share a machine must agree on shared pins.
$reqArgs  = @('pip', 'install', '--python', $vpy)
$reqNames = @()
foreach ($d in $cloned) {
    $req = Join-Path $topAbs "$d\requirements.txt"
    # MAST_control shipped this as 'required.txt' until the rename; accept the
    # old name so a not-yet-updated clone still provisions.
    if (-not (Test-Path -LiteralPath $req)) {
        $legacy = Join-Path $topAbs "$d\required.txt"
        if (Test-Path -LiteralPath $legacy) {
            $req = $legacy
            Write-Warn "${d}: using legacy 'required.txt' -- rename it to requirements.txt"
        }
        else { continue }
    }
    $reqArgs  += @('-r', $req)
    $reqNames += $d
    # requirements-dev.txt too: it is where the fleet pins ruff (ruff==0.16.0
    # in every repo) and pytest. Formatter output differs between ruff
    # versions, so a missing or unpinned ruff quietly breaks the "every repo
    # formats identically" guarantee -- see each repo's ruff.toml.
    $dev = Join-Path $topAbs "$d\requirements-dev.txt"
    if (Test-Path -LiteralPath $dev) {
        $reqArgs  += @('-r', $dev)
        $reqNames += "$d(dev)"
    }
}
if ($reqNames.Count -eq 0) {
    Write-Info 'no requirements files among the cloned repos'
}
else {
    Write-Info ("installing requirements from: {0}" -f ($reqNames -join ', '))
    if ($DryRun) {
        Write-Host ("       would run: {0} {1}" -f $uvExe, ($reqArgs -join ' '))
    }
    else {
        $code = Invoke-Native -Exe $uvExe -NativeArgs $reqArgs
        if ($code -ne 0) {
            throw ("uv pip install failed.`n" +
                   "       If it reports conflicting versions, two repos sharing this machine`n" +
                   "       pin the same package differently; reconcile the requirements files`n" +
                   "       rather than installing them separately.")
        }
    }
}

# --- sys.path wiring ------------------------------------------------------
#
# A .pth in the venv beats setting PYTHONPATH: the MAST code runs as NSSM
# services, which do not inherit a shell's environment, and a .pth also works
# automatically for pytest and IDE test runners on the same interpreter.
if ($Venv) {
    $sp = Join-Path $Venv 'Lib\site-packages'
    if (-not (Test-Path -LiteralPath $sp)) {
        $alt = @(Get-ChildItem -Path (Join-Path $Venv 'lib') -Filter 'python*' -Directory -ErrorAction SilentlyContinue)
        if ($alt.Count -gt 0) { $sp = Join-Path $alt[0].FullName 'site-packages' }
    }
    if (-not (Test-Path -LiteralPath $sp)) {
        Write-Warn ("no site-packages under '{0}' -- skipping mast.pth" -f $Venv)
    }
    else {
        $pth = Join-Path $sp 'mast.pth'
        Write-Info ("writing {0} -> {1}" -f $pth, $topAbs)
        if (-not $DryRun) {
            Set-Content -LiteralPath $pth -Value $topAbs -Encoding ASCII
        }
    }
}

# --- VS Code multi-root workspace -----------------------------------------
#
# Opening <Top> as a plain folder makes VS Code read only <Top>\.vscode, so the
# per-repo .vscode directories (control, spec, gui and unit each ship one) are
# ignored. A multi-root workspace is the one arrangement where every repo keeps
# its own folder-scoped settings.json and its launch.json entries, with no
# copying or merging: the repos stay the source of truth.
#
# Written only when absent -- people customise these, and silently clobbering a
# hand-edited workspace on every -Update would be its own bug.
$wsName = 'mast-' + (($selected | Sort-Object) -join '-') + '.code-workspace'
$ws = Join-Path $topAbs $wsName
if (Test-Path -LiteralPath $ws) {
    Write-Info "$wsName exists, leaving it alone"
}
elseif ($DryRun) {
    Write-Host "       would write $ws"
}
else {
    Write-Info "writing $ws"
    $folders = ($cloned | ForEach-Object { '    { "path": "' + $_ + '" }' }) -join ",`n"
    # Absolute, because <Top>\.venv is a sibling of the folder roots rather than
    # inside one, so VS Code cannot auto-discover it. This file is generated per
    # machine, so a machine-specific path here is fine. JSON needs the
    # backslashes escaped.
    # JSON needs each backslash doubled. The replacement string is .NET's, where
    # a backslash is literal (not an escape), so two backslashes here produce
    # exactly two in the file -- four would decode back to a doubled separator.
    $interp = (Join-Path $Venv 'Scripts\python.exe') -replace '\\', '\\'
    $lines = @(
        '{',
        '  "folders": [',
        $folders,
        '  ],',
        '  "settings": {',
        ('    "python.defaultInterpreterPath": "' + $interp + '",'),
        # Relative to each folder root, i.e. <Top>. This is what makes Pylance
        # resolve 'common' in every folder: mast.pth fixes runtime, but static
        # analysis does not reliably follow .pth files.
        '    "python.analysis.extraPaths": [".."],',
        # The Ruff extension ships its own ruff and uses it by default, which
        # would silently ignore the pinned ruff==0.16.0 installed above.
        '    "ruff.importStrategy": "fromEnvironment",',
        '    "files.exclude": { ".venv": true, ".tools": true }',
        '  },',
        # Recommendations only prompt; they never install. Installing is
        # provisioning's job (code --install-extension), not this script's -- a
        # unit may have no editor at all. Listed because the repos' own settings
        # depend on them: Pylance for the language server, ruff as the configured
        # formatter, debugpy for the "type": "debugpy" launch configs, PowerShell
        # for the one PS launch config.
        '  "extensions": {',
        '    "recommendations": [',
        '      "ms-python.python",',
        '      "ms-python.vscode-pylance",',
        '      "ms-python.debugpy",',
        '      "charliermarsh.ruff",',
        '      "ms-vscode.PowerShell"',
        '    ]',
        '  }',
        '}'
    )
    Set-Content -LiteralPath $ws -Value $lines -Encoding ascii
}

# --- shadowing guard ------------------------------------------------------
#
# With <Top> on sys.path the sibling folders become importable top-level names,
# and three of them collide with real modules: spec\spec.py, unit\src\unit.py,
# control\control\. Python resolves these correctly ONLY because those repo
# roots have no __init__.py (a dir without one is a mere namespace portion, and
# a real module found anywhere on the path beats it). If someone ever adds an
# __init__.py to a consumer repo root, that repo silently shadows its own
# module. Fail loudly here rather than debugging it later.
$shadowProblems = $false
foreach ($d in $cloned) {
    if ($d -eq 'common') { continue }   # common's root __init__.py is required
    if (Test-Path -LiteralPath (Join-Path (Join-Path $topAbs $d) '__init__.py')) {
        Write-Warn ("{0}\__init__.py exists -- it will shadow '{0}' as a package and break imports" -f $d)
        $shadowProblems = $true
    }
}

Write-Host ''
if ($shadowProblems) { Write-Warn 'shadowing problems detected (see above)' }
Write-Info ("done. {0} folder(s) under {1}" -f $cloned.Count, $topAbs)
Write-Host ''
Write-Host ("  Open {0} in VS Code, or activate the venv:" -f $ws)
Write-Host ("    {0}" -f (Join-Path $Venv 'Scripts\Activate.ps1'))
