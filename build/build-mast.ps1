[CmdletBinding()]
param(
  [string]${Top},                                                   # path to <TOP>
  [Parameter(Mandatory)]
    [ValidateScript({
        if (-not $_) {
            throw "Parameter -HostName must be supplied."
        }
        if ($_ -notmatch '^(mast(w|0[0-9]|[1-9]|1[0-9]|20)|mast-[a-z]+-[0-9]+)$') {
            throw "Parameter -HostName must match 'mastw', 'mast00', 'mast01'..'mast20', or 'mast-<site>-NN'."
        }
        $true
    })]
  [string]${HostName},
  # Modules to build. When not provided (or empty), the default is the full
  # set of providers discovered on disk under server/providers/, sorted by
  # their module.json 'order' field. Pass an explicit list to build a subset.
  # See Resolve-DefaultModules below for the discovery logic; see
  # server/providers/*/module.json for the source of truth.
  [string[]]${Modules} = @(),
  # Dev/test: allow missing NoMachine license files (skip staging nomachine.lic).
  [switch]${AllowMissingNoMachineLicense},
  # Dev/test: allow missing NetFx3 SxS source (skip staging sxs\; provider
  # falls back to online DISM with a warning). Production builds MUST have
  # the bundled SxS present -- the online DISM path depends on WU CDN
  # reachability + throughput, which contradicts the project's reliability
  # goal. See server/providers/ascom/assets/sxs/README.md.
  [switch]${AllowMissingNetFx3Sxs},
  # Dev/test: allow missing large optional assets (skip with warning).
  [switch]${TestMode},
  # Proxy mode for this build, baked into the staged commands.json:
  #   weizmann -> proxy provider gets -ForceMode use.
  #   direct   -> proxy provider gets -ForceMode direct.
  # (astrometry-dependencies no longer takes a proxy mode: its cygwin install
  # is fully offline from the staged frozen package cache -- see issue #20.)
  # Default is 'weizmann' (the common on-campus case). Runs against a unit
  # that cannot reach bcproxy MUST override to 'direct' -- regardless of
  # whether the run is dev or prod; the deciding factor is purely the
  # unit's network reachability. `vm/run-prov-test.py --proxy-mode direct`
  # is the canonical way to do so. See DECISIONS.md 2026-05-26.
  [ValidateSet('weizmann','direct')]
  [string]${ProxyMode} = 'weizmann',

  # Mount type baked into the imdisk module command. 'vm' (production default):
  # RAM-backed volatile D:, commits the full 32 GB of virtual memory -- fine on
  # 64 GB units, IMPOSSIBLE on the 8 GB dev VM (imdisk exits 3, ENOMEM).
  # 'file': plain file-backed mount so dev-VM cycles still get D:\mast-indexes
  # (writes persist into the .img -- acceptable for a throwaway snapshot-reset
  # VM). vm/run-prov-test.py always builds with 'file'.
  [ValidateSet('vm','file')]
  [string]${ImdiskMountType} = 'vm',

  # Site whose bootstrap profile (server/providers/config-bootstrap/sites/<Site>.toml)
  # becomes the unit's C:\WIS\config.toml via the config-bootstrap provider. Selected
  # EXPLICITLY here, never derived from the hostname (per the config-file epic). The
  # config-bootstrap switch case below validates it against the available profiles.
  [string]${Site} = 'wis'
)

# Normalize -Modules: subprocess passes comma-joined strings as a single element.
if (${Modules}.Count -eq 1 -and ${Modules}[0] -match ',') {
    ${Modules} = @(${Modules}[0].Split(',') | Where-Object { $_ -ne '' })
}

# Elevation is not required for the build itself, but mklink/junction optimizations
# in New-LinkOrCopy are only available when running as Administrator.
${isAdmin} = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not ${isAdmin}) {
    Write-Warning "Running non-elevated. Linking optimizations disabled; assets will be copied instead."
}

# Set-StrictMode -Version Latest
${ErrorActionPreference} = 'Stop'

# Paths
if (-not $Top -or [string]::IsNullOrWhiteSpace($Top)) {
    $Top = Split-Path -Parent $PSScriptRoot
}

[string]${OutRoot} = (Join-Path ${Top} 'staging')

# If the folder does not exist, create it (recursively)
if (-not (Test-Path -Path $Top -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Top | Out-Null
    Write-Host "Created missing folder: $Top"
}

# --- Disk-space validation (provisioning machine) ---
# A full staging payload is ~10-11 GB (dominated by the astrometry index seed
# files). Fail fast if the staging drive is low rather than writing a truncated
# payload that then breaks the unit-side pull (robocopy rc>=8) deep into a run.
${OutDrive} = Split-Path -Qualifier ${OutRoot}
${minFreeGb} = 20
${freeBytes} = $null
try { ${freeBytes} = (Get-PSDrive -Name (${OutDrive}.TrimEnd(':')) -ErrorAction Stop).Free } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
if ($null -eq ${freeBytes}) {
    Write-Warning ("[disk] could not resolve staging drive {0}; skipping free-space check." -f ${OutDrive})
} else {
    ${freeGb} = [math]::Round(${freeBytes} / 1GB, 1)
    Write-Host ("[disk] staging drive {0} free={1} GB (min {2} GB)" -f ${OutDrive}, ${freeGb}, ${minFreeGb})
    if (${freeBytes} -lt ([int64]${minFreeGb} * 1GB)) {
        throw ("Insufficient free space on staging drive {0}: {1} GB free, need >= {2} GB. Free up space (old staging\ payloads, temp files) and re-run." -f ${OutDrive}, ${freeGb}, ${minFreeGb})
    }
}

${serverRoot} = Join-Path ${Top} 'server'
${clientRoot} = Join-Path ${Top} 'client'
${vault} = Join-Path ${Top} 'vault'
${serverLib}   = Join-Path ${serverRoot} 'lib\provisioning.psm1'
${providersRoot} = Join-Path ${serverRoot} 'providers'
if (-not (Test-Path ${serverLib})) { throw "Missing provisioning.psm1 at ${serverLib}" }

# Provider/site discovery lib (no admin required). Imported unconditionally so
# both the site-list guard below and the -Modules default path use one import.
${modulesLib} = Join-Path ${serverRoot} 'lib\mast-modules.psm1'
if (-not (Test-Path ${modulesLib})) { throw "Missing mast-modules.psm1 at ${modulesLib}" }
Import-Module ${modulesLib} -Force -DisableNameChecking

# Staging helpers (repofiles resolution + containment). Dot-sourced so the same
# implementation is what server/tests/build-staging-lib.Tests.ps1 exercises.
${stagingLib} = Join-Path ${PSScriptRoot} 'build-staging-lib.ps1'
if (-not (Test-Path ${stagingLib})) { throw "Missing build-staging-lib.ps1 at ${stagingLib}" }
. ${stagingLib}

# Bootstrap element-registry helpers, dot-sourced for the same reason:
# server/tests/build-bootstrap-lib.Tests.ps1 exercises this implementation.
${bootstrapLib} = Join-Path ${PSScriptRoot} 'build-bootstrap-lib.ps1'
if (-not (Test-Path ${bootstrapLib})) { throw "Missing build-bootstrap-lib.ps1 at ${bootstrapLib}" }
. ${bootstrapLib}

# NoMachine certificate guards, dot-sourced for the same reason:
# server/tests/build-nomachine-lib.Tests.ps1 exercises this implementation.
${licensesLib} = Join-Path ${PSScriptRoot} 'build-nomachine-lib.ps1'
if (-not (Test-Path ${licensesLib})) { throw "Missing build-nomachine-lib.ps1 at ${licensesLib}" }
. ${licensesLib}

[string]${LicensesRoot} = (Join-Path ${Top} 'vault\nomachine-licenses')
${licensesVault} = (Join-Path ${vault} 'nomachine-licenses')

# Read a module manifest: modules\<name>\module.json
function Read-ModuleManifest {
    param([Parameter(Mandatory)][string]$ModuleName)
    $path = Join-Path (Join-Path ${providersRoot} $ModuleName) 'module.json'
    if (-not (Test-Path $path)) { throw "Missing module.json for module '$ModuleName' at $path" }
    return Get-Content $path -Raw | ConvertFrom-Json
}

# Guard the single source of truth for the site list. The authoritative set of
# sites is the *.toml profiles under config-bootstrap/sites/. The offline
# bootstrap script (client/bootstrap.ps1) cannot read that directory -- it
# runs on a bare unit from USB/ISO before the prov server is reachable -- so it
# embeds a $knownSites list for early operator validation at the console. This
# guard runs on the prov server (where both are visible) and fails the build if
# the embedded list has drifted from sites/, so the offline copy can never
# silently diverge. Parses the literal assignment rather than dot-sourcing the
# script (which is admin-only and has side effects).
function Assert-BootstrapKnownSitesInSync {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]${ClientRoot},
    [Parameter(Mandatory)][string]${ProvidersRoot}
  )
  ${bootstrapScript} = Join-Path ${ClientRoot} 'bootstrap.ps1'
  if (-not (Test-Path -LiteralPath ${bootstrapScript})) {
    throw ('Cannot verify site-list sync: bootstrap script not found at {0}' -f ${bootstrapScript})
  }
  ${configured} = @(Get-ConfiguredSites -ProvidersRoot ${ProvidersRoot})

  ${text} = Get-Content -LiteralPath ${bootstrapScript} -Raw -Encoding UTF8
  ${m} = [regex]::Match(${text}, '\$knownSites\s*=\s*@\(([^)]*)\)')
  if (-not ${m}.Success) {
    throw ('Cannot find a ''$knownSites = @(...)'' assignment in {0} to verify against sites/.' -f ${bootstrapScript})
  }
  ${embedded} = @(
    [regex]::Matches(${m}.Groups[1].Value, "'([^']*)'") |
      ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() } |
      Sort-Object
  )

  ${missing} = @(${configured} | Where-Object { ${embedded} -notcontains $_ })
  ${extra}   = @(${embedded}   | Where-Object { ${configured} -notcontains $_ })
  if (${missing}.Count -gt 0 -or ${extra}.Count -gt 0) {
    ${msg} = 'bootstrap.ps1 $knownSites is out of sync with config-bootstrap/sites/.'
    if (${missing}.Count -gt 0) { ${msg} += (' Missing from $knownSites: {0}.' -f (${missing} -join ', ')) }
    if (${extra}.Count -gt 0)   { ${msg} += (' In $knownSites but no matching sites/*.toml: {0}.' -f (${extra} -join ', ')) }
    ${msg} += (' Configured sites: {0}. Update the $knownSites list in {1} to match.' -f (${configured} -join ', '), ${bootstrapScript})
    throw ${msg}
  }
  Write-Host ('[build-mast] Site list in sync: {0} (bootstrap.ps1 $knownSites matches config-bootstrap/sites/).' -f (${configured} -join ', '))
}

# The memory figure has the same shape of problem as the site list: bootstrap runs
# offline on a bare unit and must embed it, while the provisioning side reads it from
# mast-modules.psm1. Only one of the two is authoritative, and only the build can see
# both -- so the build is where a half-edit is caught.
function Assert-BootstrapMemoryRequirementInSync {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]${ClientRoot}
  )
  ${bootstrapScript} = Join-Path ${ClientRoot} 'bootstrap.ps1'
  if (-not (Test-Path -LiteralPath ${bootstrapScript})) {
    throw ('Cannot verify the memory requirement: bootstrap script not found at {0}' -f ${bootstrapScript})
  }
  ${required} = Get-MastRequiredMemoryGB

  ${text} = Get-Content -LiteralPath ${bootstrapScript} -Raw -Encoding UTF8
  ${m} = [regex]::Match(${text}, '\$script:RequiredMemoryGB\s*=\s*(\d+)')
  if (-not ${m}.Success) {
    throw ('Cannot find a ''$script:RequiredMemoryGB = <n>'' assignment in {0} to verify against Get-MastRequiredMemoryGB.' -f ${bootstrapScript})
  }
  ${embedded} = [int]${m}.Groups[1].Value
  if (${embedded} -ne ${required}) {
    throw ("bootstrap.ps1 `$script:RequiredMemoryGB is {0} GB but Get-MastRequiredMemoryGB (server\lib\mast-modules.psm1) says {1} GB. Update {2} to match; the module is the authoritative declaration." -f ${embedded}, ${required}, ${bootstrapScript})
  }
  Write-Host ('[build-mast] Memory requirement in sync: {0} GB (bootstrap.ps1 matches Get-MastRequiredMemoryGB).' -f ${required})
}

# The jupyter provider's vendored wheelhouse is bound to a CPython version that
# the 'python' provider declares, and neither module can see the other. Same
# shape as the two bootstrap guards above -- two sources of truth that only the
# build can compare -- and the same resolution: fail the build rather than the
# fleet. That provider installs '--no-index', so a mismatch is not a slower
# resolve but a failed module on every unit, with no remedy on the unit (#180).
#
# Runs when EITHER module is staged, not only jupyter: the edit that breaks this
# is a version bump in the python provider, and a '--modules python' build would
# otherwise ship a new interpreter to a unit whose jupyter venv was built from
# the old wheels. The check reads the two declarations, not the payload, so it
# costs nothing when jupyter is not being staged.
function Assert-JupyterWheelhouseInterpreterInSync {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]${ProvidersRoot}
  )
  # Read through ${ProvidersRoot} rather than via Read-ModuleManifest, which
  # takes its root from a script-scope ${providersRoot}: PowerShell resolves that
  # up the dynamic scope chain and case-insensitively, so from inside a function
  # holding a ${ProvidersRoot} PARAMETER it lands on the parameter instead. Same
  # value in a build, and a silent coupling that made this guard untestable
  # against any root but the live one. Everything it reads is now its argument.
  ${pythonModuleJson} = Join-Path ${ProvidersRoot} 'python\module.json'
  if (-not (Test-Path -LiteralPath ${pythonModuleJson})) {
    throw "Cannot verify the Jupyter wheelhouse: no python module.json at ${pythonModuleJson}."
  }
  ${pythonManifest} = Get-Content -LiteralPath ${pythonModuleJson} -Raw | ConvertFrom-Json
  if (-not ${pythonManifest}.PSObject.Properties.Match('version').Count -or
      [string]::IsNullOrWhiteSpace(${pythonManifest}.version)) {
    throw "Cannot verify the Jupyter wheelhouse: ${pythonModuleJson} declares no 'version'."
  }
  ${pinned} = [string]${pythonManifest}.version

  ${wheelDir} = Join-Path ${ProvidersRoot} 'jupyter\assets\wheels'
  ${wheelNames} = @()
  if (Test-Path -LiteralPath ${wheelDir}) {
    ${wheelNames} = @(
      Get-ChildItem -LiteralPath ${wheelDir} -Filter '*.whl' -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name }
    )
  }
  # An EMPTY wheelhouse is deliberately not this guard's business: it is already
  # caught where it matters, by the staging throw that refuses to build a jupyter
  # payload with no wheels. Here it is vacuously in sync.
  if (${wheelNames}.Count -eq 0) { return }

  ${mismatches} = @(Get-MastWheelInterpreterMismatches -PythonVersion ${pinned} -WheelNames ${wheelNames})
  if (${mismatches}.Count -gt 0) {
    ${msg} = ("Jupyter wheelhouse does not match the interpreter the 'python' provider pins ({0}): {1} of {2} wheels disagree." -f ${pinned}, ${mismatches}.Count, ${wheelNames}.Count)
    foreach (${reason} in ${mismatches}) { ${msg} += ("`n  {0}" -f ${reason}) }
    ${msg} += ("`nThat provider installs with --no-index and cannot fall back to PyPI, so this would fail the jupyter module on every unit. Either revert the version in server/providers/python/module.json, or regenerate both artifacts against the new interpreter: refreeze server/providers/jupyter/assets/requirements.txt and re-run 'pip download -r assets/requirements.txt -d assets/wheels --only-binary=:all:' on a Windows host running the fleet's Python. Regenerating is a deliberate act with an owner -- see the header of requirements.txt.")
    throw ${msg}
  }
  Write-Host ('[build-mast] Jupyter wheelhouse in sync: {0} wheels agree with the pinned interpreter {1}.' -f ${wheelNames}.Count, ${pinned})
}

Assert-BootstrapKnownSitesInSync -ClientRoot ${clientRoot} -ProvidersRoot ${providersRoot}
Assert-BootstrapMemoryRequirementInSync -ClientRoot ${clientRoot}
Assert-MastBootstrapElementRegistry -ClientRoot ${clientRoot} -ProvidersRoot ${providersRoot}
Assert-MastNoNoMachineCertsInAssets -AssetsLicenseDir (Join-Path ${providersRoot} 'nomachine\assets\licenses')

# If no -Modules were passed (or the normalization above collapsed to empty),
# default to the providers discovered on disk. Get-AllProviderModules lives in
# server/lib/mast-modules.psm1 (no admin required) so build-mast can call it
# even when running non-elevated; the driver resolves the same
# module so both use the single source of truth.
if ($null -eq ${Modules} -or ${Modules}.Count -eq 0) {
    ${Modules} = Get-AllProviderModules -ProvidersRoot ${providersRoot}
    Write-Host ("Modules defaulted to {0} providers discovered under {1}." -f ${Modules}.Count, ${providersRoot})
}

if (${Modules} -contains 'jupyter' -or ${Modules} -contains 'python') {
    Assert-JupyterWheelhouseInterpreterInSync -ProvidersRoot ${providersRoot}
}

# Create a junction/hardlink/symlink into staging; fallback to copy if linking not allowed
function New-LinkOrCopy {
    param([Parameter(Mandatory)][string]$Target,
          [Parameter(Mandatory)][string]$LinkPath)

    $parent = Split-Path $LinkPath -Parent
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    if (Test-Path $LinkPath) { Remove-Item -Force -Recurse $LinkPath -ErrorAction SilentlyContinue }

    $isDir = Test-Path $Target -PathType Container

    # Non-admin mode: avoid mklink/junction attempts entirely (they can trigger permission errors / UAC prompts).
    if (-not ${isAdmin}) {
        if ($isDir) {
            robocopy "$Target" "$LinkPath" /E /NFL /NDL /NJH /NJS /NP | Out-Null
        } else {
            Copy-Item -Force $Target $LinkPath
        }
        return
    }

    # Prefer junction for directories (no Developer Mode needed)
    if ($isDir) {
        try { cmd /c "mklink /J `"$LinkPath`" `"$Target`"" | Out-Null; return } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
    } else {
        # Try hardlink for files (same volume required)
        # A hardlink shares the target's single ACL. The asset-cache files have
        # inheritance disabled and no mast-transfer ACE, so the read-only SMB pull
        # account is denied on every linked binary (only copied, inheriting files
        # come through). Re-enable inheritance on the staged link so it picks up the
        # staging dir's mast-transfer:(RX) inherited ACE.
        try {
            cmd /c "mklink /H `"$LinkPath`" `"$Target`"" | Out-Null
            if (Test-Path $LinkPath) {
                cmd /c "icacls `"$LinkPath`" /inheritance:e" | Out-Null
                return
            }
        } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
    }

    # Try symlink
    try {
        if ($isDir) {
            New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target -Force | Out-Null
        } else {
            New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target -Force | Out-Null
        }
        return
    } catch { Write-Verbose "ignored: $($_.Exception.Message)" }

    # Fallback: copy (may fail for large files on VirtFS - non-fatal, orchestrator sources directly)
    if ($isDir) {
        robocopy "$Target" "$LinkPath" /E /NFL /NDL /NJH /NJS /NP | Out-Null
    } else {
        try { Copy-Item -Force $Target $LinkPath } catch {
            Write-Warning "Skipping large-file copy for $(Split-Path $Target -Leaf): VirtFS size limit"
        }
    }
}

# Optional: load/parse license allocation CSV (if preallocating)
function Import-AllocCsv([string]${Path}) {
  if (-not (Test-Path ${Path})) { return @() }
  try { return (Import-Csv -Path ${Path}) } catch {
    # barebones manual parse (license,host)
    ${rows}=@(); foreach (${line} in Get-Content ${Path}) {
      if (-not ${line} -or ${line} -match '^license,') { continue }
      ${p}=${line}.Split(',',2); if (${p}.Count -ge 2) { ${rows}+=[pscustomobject]@{license=${p}[0].Trim();host=${p}[1].Trim()} }
    }; return ${rows}
  }
}

function Save-AllocCsv([string]${Path}, [object[]]${Rows}) {
    ${tmp} = "${Path}.tmp"
    ${Rows} | Export-Csv -Path ${tmp} -NoTypeInformation -Encoding UTF8 -Force -Delimiter ','
    Move-Item -Force ${tmp} ${Path}
    Write-Host "Updated allocation file: ${Path}"
}

${allocCsv} = Join-Path ${TOP} 'server\providers\nomachine\assets\licenses\allocated.csv'
# allocRows
${allocRows} = Import-AllocCsv ${allocCsv}

# Report on EVERY seat the fleet owns, not just the one this build stages. A
# seat allocated to a host no build runs for -- mast-ns-spec holds one and is
# not in unit-registry.json -- is otherwise checked by nothing. Grouped by
# expiry date, because all ten seats share one, and ten identical warnings is
# the worst way to say a single renewal is due. Never fails the build.
${allocMap} = @{}
foreach (${row} in ${allocRows}) {
    if (${row}.license) { ${allocMap}[[string]${row}.license] = [string]${row}.host }
}
${null} = Show-MastNoMachineStoreSummary -StoreDir ${LicensesRoot} -AllocationByLicense ${allocMap}

# allLicFiles
${allLicFiles} = Get-ChildItem -Path ${licensesVault} -Filter '*.lic' -File -ErrorAction SilentlyContinue | Sort-Object Name

# Translate the build-level ProxyMode (weizmann|direct) into the values that
# the individual providers expect on their own command lines.
${proxyForceMode}    = if (${ProxyMode} -eq 'weizmann') { 'use' } else { 'direct' }
# Per-site RPi NTP server (the #1 time peer); injected into the timesync command by -Site.
# Single source of the per-site RPi value. Sites without one are simply absent (RPi tier skipped).
${siteRpiNtp} = @{ 'ns' = '10.23.1.222' }

# Banner: print the chosen mode prominently so an operator scanning a build
# log can tell at a glance which mode this staging directory was built for.
${proxyBanner} = if (${ProxyMode} -eq 'weizmann') { '*** WEIZMANN-PROXY MODE ***' } else { '*** NO-WEIZMANN-PROXY (DIRECT) MODE ***' }
Write-Host "==================================================================="
Write-Host ("[build-mast] {0}" -f ${proxyBanner})
Write-Host ("[build-mast] proxy provider           -> -ForceMode {0}" -f ${proxyForceMode})
Write-Host  "[build-mast] astrometry-dependencies  -> offline (frozen cygwin-pkg-cache; no proxy mode)"
Write-Host "==================================================================="

# Build commands list once (same for all), then tweak per host only if we add a SingleLicensePath
function New-CommandFile([string[]]${Mods}) {
  ${cmds}=@()
  foreach (${m} in ${Mods}) {
    ${mf}=Read-ModuleManifest -ModuleName ${m}

    # base command from manifest
    ${cmd} = [string]${mf}.command

    # Per-module command tweaks driven by build-time -ProxyMode. We bake the
    # mode into the command string here (rather than communicating via env
    # vars or smoke markers at runtime) so it is visible in commands.json
    # and survives across the WinRM boundary unambiguously.
    switch (${m}) {
      'proxy' {
        ${cmd} = ${cmd} + (" -ForceMode {0}" -f ${proxyForceMode})
      }
      'mast' {
        # tools/mast-clone.ps1 routes ALL its outbound HTTPS (clones, the uv
        # download, PyPI) through the Weizmann bcproxy by default, regardless of
        # -Transport. On a machine that cannot reach bcproxy -- the dev VM, or a
        # site with open egress -- that proxy does not refuse, it TIMES OUT, so
        # the failure looks like a hung script for minutes. mast-clone's
        # -DirectHttp clears the proxy variables (rather than merely skipping
        # them, so an inherited https_proxy cannot make the flag a no-op), which
        # is exactly what a 'direct' build means. Same channel as the proxy
        # provider above: baked into commands.json, not signalled at runtime.
        if (${ProxyMode} -ne 'weizmann') {
          ${cmd} = ${cmd} + ' -DirectHttp'
        }
      }
      'imdisk' {
        if (${ImdiskMountType} -ne 'vm') {
          ${cmd} = ${cmd} + (" -MountType {0}" -f ${ImdiskMountType})
        }
        # The fleet requirement travels with the command rather than being a
        # default in the provider, so there is one declaration of the number
        # (Get-MastRequiredMemoryGB) instead of a copy per consumer. The
        # provider only asserts it for a '-t vm' mount -- the dev VM's
        # file-backed mount commits nothing and is exempt by construction.
        ${cmd} = ${cmd} + (" -MinMemoryGB {0}" -f (Get-MastRequiredMemoryGB))
      }
      'config-bootstrap' {
        # Inject the explicitly-selected -Site so the provider deploys
        # sites/<Site>.toml as C:\WIS\config.toml. Fail the build early with a
        # helpful message if that site has no profile.
        ${siteProfile} = Join-Path ${providersRoot} ('config-bootstrap\sites\{0}.toml' -f ${Site})
        if (-not (Test-Path -LiteralPath ${siteProfile})) {
          ${avail} = (Get-ConfiguredSites -ProvidersRoot ${providersRoot}) -join ', '
          throw ("-Site '{0}' has no profile at {1}. Available sites: {2}" -f ${Site}, ${siteProfile}, ${avail})
        }
        ${cmd} = ${cmd} + (" -Site {0}" -f ${Site})
      }
      'timesync' {
        # Inject the per-site RPi NTP (priority-1 peer) when the selected site has one.
        # Site-specific like config-bootstrap -- never derived from the hostname.
        if (${siteRpiNtp}.ContainsKey(${Site})) {
          ${cmd} = ${cmd} + (" -RpiNtp {0}" -f ${siteRpiNtp}[${Site}])
        }
      }
      'mast-validation' {
        # Dev-VM escape: forward --allow-missing-avx to the python validator
        # under -TestMode. astrometry-engine crashes with SIGILL on guest CPUs
        # without AVX/AVX2/FMA (e.g. the VirtualBox dev VM); TestMode treats
        # that specific failure as SKIPPED. Production MUST NOT pass TestMode.
        # Corrupt index files remain a hard FAIL regardless. See DECISIONS.md.
        if (${TestMode}) { ${cmd} = ${cmd} + ' -AllowMissingAvx' }
      }
    }

    ${cmds} += [pscustomobject]@{ order = [int]${mf}.order; desc = [string]${mf}.description; cmd = ${cmd}; module = ${m} }

    if (${mf}.verify) {
      ${verifyCmd} = [string]${mf}.verify
      # Same dev-VM escape on the verify side: verify-astrometry.ps1 understands
      # -AllowMissingAvx (the only verify that runs a real solve and thus the
      # only one exposed to the AVX SIGILL).
      if (${TestMode} -and ${m} -eq 'astrometry') {
          ${verifyCmd} = ${verifyCmd} + ' -AllowMissingAvx'
      }
      # Dev-VM escape: verify-usbpcap.ps1 requires the kernel driver service
      # to be registered, which only happens after the post-install reboot we
      # do not perform inside the WinRM run. Under -TestMode forward
      # -AllowPendingReboot so the "exe present + service absent" state is
      # treated as SKIPPED instead of FAIL. Production MUST NOT pass TestMode.
      if (${TestMode} -and ${m} -eq 'usbpcap') {
          ${verifyCmd} = ${verifyCmd} + ' -AllowPendingReboot'
      }
      ${cmds} += [pscustomobject]@{ order = [int](${mf}.order + 1); desc = "[verify] " + [string]${mf}.name; cmd = ${verifyCmd}; module="${m}-verify" }
    }
  }

  # --- End-of-provisioning networking finalization ---------------------
  # A deployed unit always lives on the Weizmann network and needs the
  # bcproxy HTTP proxy, no matter how it was provisioned. We honour the
  # build-time -ProxyMode for the DURATION of the run (a 'direct' run on a
  # bench that genuinely cannot reach bcproxy must install without it), but
  # as the last functional step -- after every installer, before the
  # reboot-detection provider (order 9999) -- we re-assert the Weizmann
  # proxy on every surface so the unit ships proxy-ready. In 'weizmann'
  # builds this is an idempotent re-assert; in 'direct' builds it flips
  # the machine env / WinINet / WinHTTP proxy from direct to bcproxy.
  # Nothing network-dependent runs after this step, so flipping a 'direct'
  # bench unit onto the proxy here cannot break a later installer. Reuses
  # the proxy provider (DRY) with a hard -ForceMode use, and re-runs its
  # verify so the shipped proxy state is confirmed, not assumed.
  if (${Mods} -contains 'proxy') {
    ${proxyMf} = Read-ModuleManifest -ModuleName 'proxy'
    ${finalizeCmd} = [string]${proxyMf}.command + ' -ForceMode use'
    ${cmds} += [pscustomobject]@{ order = 9000; desc = 'Finalize networking: re-assert the Weizmann bcproxy HTTP proxy on every surface (machine env, WinINet, WinHTTP) so the unit ships proxy-ready regardless of the provisioning-time -ProxyMode. Idempotent in weizmann mode; flips direct->proxy in direct mode.'; cmd = ${finalizeCmd}; module = 'proxy' }
    if (${proxyMf}.verify) {
      ${cmds} += [pscustomobject]@{ order = 9001; desc = '[verify] proxy (post-finalize)'; cmd = [string]${proxyMf}.verify; module = 'proxy-verify' }
    }
  }

  return (${cmds} | Sort-Object order, desc)
}

${baseCmds} = New-CommandFile -Mods ${Modules}

${stagingTop} = Join-Path ${OutRoot} ${HostName}
New-Item -ItemType Directory -Force -Path ${stagingTop} | Out-Null

${clientRoot} = Join-Path ${Top} 'client'

# Helper: ensure a staging stage exists AND is empty before we populate it.
# Without this, files from prior builds (e.g. an older installer version that
# the provider's asset dir no longer ships) linger in staging forever, inflate
# the SMB transfer to the unit, and can confuse unit-side scripts looking for
# "the" installer by glob. New-Item -Force only creates-if-missing; the wipe
# below is what guarantees idempotence.
function Reset-StagingStage {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        # Wipe contents, keep the directory itself in case anything is watching the path.
        Get-ChildItem -LiteralPath $Path -Force | Remove-Item -Recurse -Force
    } else {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

# Actual provisioning
${staging} = Join-Path ${stagingTop} "01-provisioning"
Reset-StagingStage -Path ${staging}
Write-Host "Populating provisioning stage ${staging} ..."

# Always place provisioning.psm1 into staging
Copy-Item -Force ${serverLib} (Join-Path ${staging} 'provisioning.psm1')
${mastLogLib} = Join-Path (Split-Path -Parent ${serverLib}) 'mast-log.ps1'
if (-not (Test-Path ${mastLogLib})) { throw "Missing mast-log.ps1 at ${mastLogLib}" }
Copy-Item -Force ${mastLogLib} (Join-Path ${staging} 'mast-log.ps1')
${mastNetLib} = Join-Path (Split-Path -Parent ${serverLib}) 'mast-net.ps1'
if (-not (Test-Path ${mastNetLib})) { throw "Missing mast-net.ps1 at ${mastNetLib}" }
Copy-Item -Force ${mastNetLib} (Join-Path ${staging} 'mast-net.ps1')
# Unconditional, not a commandfile of the mast module: verify-mast.ps1 dot-sources
# it, and a verify-only rerun can be built from any module subset (#177).
${mastCurrencyLib} = Join-Path (Split-Path -Parent ${serverLib}) 'mast-git-currency.ps1'
if (-not (Test-Path ${mastCurrencyLib})) { throw "Missing mast-git-currency.ps1 at ${mastCurrencyLib}" }
Copy-Item -Force ${mastCurrencyLib} (Join-Path ${staging} 'mast-git-currency.ps1')

# Copy client execution script into staging
${executeScript} = Join-Path ${clientRoot} 'execute-mast-provisioning.ps1'
if (Test-Path ${executeScript}) {
    Copy-Item -Force ${executeScript} (Join-Path ${staging} 'execute-mast-provisioning.ps1')
    Write-Host " Staged execute-mast-provisioning.ps1"
} else {
    Write-Warning "execute-mast-provisioning.ps1 not found at ${executeScript}"
}

${invokeChildScript} = Join-Path ${clientRoot} 'mast-invoke-child.ps1'
if (Test-Path ${invokeChildScript}) {
    Copy-Item -Force ${invokeChildScript} (Join-Path ${staging} 'mast-invoke-child.ps1')
    Write-Host " Staged mast-invoke-child.ps1"
} else {
    Write-Warning "mast-invoke-child.ps1 not found at ${invokeChildScript}"
}

# Dot-sourced by execute-mast-provisioning.ps1 for the cumulative per-module
# installed-manifest merge. Unlike the two above this is a hard requirement:
# without it execute cannot record what it installed, so a missing file must
# fail the build rather than produce a payload that provisions and then forgets.
${installedManifestScript} = Join-Path ${clientRoot} 'mast-installed-manifest.ps1'
if (-not (Test-Path ${installedManifestScript})) {
    throw "Missing mast-installed-manifest.ps1 at ${installedManifestScript}"
}
Copy-Item -Force ${installedManifestScript} (Join-Path ${staging} 'mast-installed-manifest.ps1')
Write-Host " Staged mast-installed-manifest.ps1"

# A hard requirement for the same reason as the manifest script above: the imdisk
# provider dot-sources Test-MastMemoryRequirement from here before it will attempt
# a '-t vm' mount, so a payload without it does not degrade, it fails on the unit.
${clientUtilScript} = Join-Path ${clientRoot} 'mast-client-util.ps1'
if (-not (Test-Path ${clientUtilScript})) {
    throw "Missing mast-client-util.ps1 at ${clientUtilScript}"
}
Copy-Item -Force ${clientUtilScript} (Join-Path ${staging} 'mast-client-util.ps1')
Write-Host " Staged mast-client-util.ps1"

${verifyOnlyScript} = Join-Path ${clientRoot} 'run-verify-only.ps1'
if (Test-Path ${verifyOnlyScript}) {
    Copy-Item -Force ${verifyOnlyScript} (Join-Path ${staging} 'run-verify-only.ps1')
    Write-Host " Staged run-verify-only.ps1"
} else {
    Write-Warning "run-verify-only.ps1 not found at ${verifyOnlyScript}"
}

# Copy CommandFiles of each module into staging (flatten)
foreach (${m} in ${Modules}) {
  ${mf}=Read-ModuleManifest -ModuleName ${m}
  Write-Host "Flattening " ${m} " ..."

  if (-not ${mf}.commandfiles) {
    Write-Warning "[${m}] No commandfiles defined in module.json"
    continue
  }

  foreach (${cmdfile} in ${mf}.commandfiles) {
    ${src} = Join-Path (Join-Path ${providersRoot} ${m}) ${cmdfile}
    if (-not (Test-Path ${src})) {
        # Dev/test exception: some payloads are intentionally omitted (large artifacts).
        $norm = (${cmdfile} -replace '\\','/').ToLowerInvariant()
        if (${TestMode} -and (
            ($m -eq 'cygwin' -and $norm -eq 'assets/astrometry.tgz') -or
            # Vendored uv (18 MB): absent in a lean dev checkout. mast-clone
            # falls back to bootstrapping it from the GitHub CDN, which works
            # but is the network dependency the vendoring removes.
            ($m -eq 'mast' -and $norm -like 'assets/uv-*')
        )) {
            Write-Warning "[${m}] Optional dev/test CommandFile missing: ${src} (skipping due to -TestMode)"
            continue
        }
        throw "[${m}] missing CommandFile: ${src}"
    }

    # Flatten assets/ files to staging root; keep scripts in root
    if (${cmdfile} -like "assets/*") {
        ${dst} = Join-Path ${staging} (Split-Path ${cmdfile} -Leaf)
    } else {
        ${dst} = Join-Path ${staging} ${cmdfile}
    }

    ${dstDir} = Split-Path ${dst} -Parent
    New-Item -ItemType Directory -Force -Path ${dstDir} | Out-Null
    Write-Host " Staging " ${cmdfile} " ..."

    New-LinkOrCopy -Target ${src} -LinkPath ${dst}
  }

  # Repo-top files: shared tooling a module runs that deliberately lives outside
  # its provider dir (the 'mast' module runs tools/mast-clone.ps1, shared with
  # the control host and dev boxes). Resolved and containment-checked by
  # Resolve-MastRepoFile; staged to the staging root by leaf name, like assets.
  foreach (${repofile} in (Get-MastModuleRepoFiles -Manifest ${mf})) {
    ${rfSrc} = Resolve-MastRepoFile -RepoTop ${Top} -RelativePath ${repofile} -ModuleName ${m}
    ${rfDst} = Get-MastRepoFileStagingPath -StagingDir ${staging} -RelativePath ${repofile}
    Write-Host " Staging repofile " ${repofile} " ..."
    New-LinkOrCopy -Target ${rfSrc} -LinkPath ${rfDst}
  }
}


# clone base commands; optionally inject a per-host license into the nomachine command
${cmds} = ${baseCmds}

if (${Modules} -contains 'nomachine') {
    # do we already have a license for this host?
    ${existing} = ${allocRows} | Where-Object { $_.host -ieq ${HostName} } | Select-Object -First 1
    if (${existing}) {
        $licPath = Join-Path ${LicensesRoot} ${existing}.license
        if (Test-Path $licPath) {
            ${null} = Assert-MastNoMachineCertIsShippable -LicensePath $licPath -HostName ${HostName}
            Copy-Item -Force -Path $licPath -Destination (Join-Path ${staging} "nomachine.lic")
        } elseif (${AllowMissingNoMachineLicense}) {
            Write-Warning "NoMachine license '$licPath' missing; continuing due to -AllowMissingNoMachineLicense."
        } else {
            throw "NoMachine license '$licPath' missing. Provide the license or pass -AllowMissingNoMachineLicense for dev/test."
        }
    } else {
        ${allocatedNames} = @(${allocRows} | ForEach-Object { $_.license }) | Where-Object { $_ } | Select-Object -Unique
        ${free} = ${allLicFiles} | Where-Object { ${allocatedNames} -notcontains $_.Name } | Select-Object -First 1
        if (-not ${free}) {
            Write-Warning "No free NoMachine license left for ${HostName} (have $(@(${allLicFiles}).Count) total)."
        } else {
            ${null} = Assert-MastNoMachineCertIsShippable -LicensePath ${free}.FullName -HostName ${HostName}
            ${allocRows} += [pscustomobject]@{ license=${free}.Name; host=${HostName} }
            # stage that single .lic
            Copy-Item -Force ${free}.FullName (Join-Path ${staging} "nomachine.lic")
        }
    }
}

# NetFx3 SxS source for the ASCOM provider. Required asset in production:
# the alternative is DISM /Online /Enable-Feature pulling from the Windows
# Update CDN, which adds three external dependencies to every run (WU
# reachability, CDN throughput, no transient 5xx). Fail-loud at build time
# unless the dev/test override is in effect. Operators are pointed at the
# provider's own README to populate the directory once -- this is a
# bounded, documented fetch quest, not an open-ended hunt.
if (${Modules} -contains 'ascom') {
    ${sxsSrc} = Join-Path ${providersRoot} 'ascom\assets\sxs'
    # One directory per OS build (assets\sxs\<build>\). Counting .cab files
    # anywhere under sxs\ is what let a Windows 11 26100 payload ship to a fleet
    # of 19044 units and present as a working asset until a unit whose component
    # store lacked the NetFx3 payload finally had to use it (#124). A build
    # directory holding at least one cab is the thing worth asserting.
    ${sxsBuilds} = @()
    if (Test-Path -LiteralPath ${sxsSrc}) {
        ${sxsBuilds} = @(Get-ChildItem -LiteralPath ${sxsSrc} -Directory -ErrorAction SilentlyContinue |
            Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -Filter '*.cab' -File -ErrorAction SilentlyContinue).Count -gt 0 })
    }
    if (${sxsBuilds}.Count -gt 0) {
        # Stage every build's payload; the provider selects the directory matching
        # the unit's own OS build, which is the only party that knows it for sure.
        ${sxsDst} = Join-Path ${staging} 'sxs'
        New-Item -ItemType Directory -Force -Path ${sxsDst} | Out-Null
        Copy-Item -Force -Recurse -Path (Join-Path ${sxsSrc} '*') -Destination ${sxsDst}
        Write-Host (" Staged NetFx3 SxS payloads for build(s) {0} -> {1}" -f ((${sxsBuilds} | ForEach-Object { $_.Name }) -join ', '), ${sxsDst})
    } elseif (${AllowMissingNetFx3Sxs}) {
        Write-Warning "No per-build NetFx3 SxS payload under '$sxsSrc'; continuing due to -AllowMissingNetFx3Sxs (provider will fall back to online DISM)."
    } else {
        throw "No per-build NetFx3 SxS payload under '$sxsSrc'. Expected at least one '<build>\*.cab' directory, e.g. '19044\' -- see the provider README for fetching one from a matching ISO. Pass -AllowMissingNetFx3Sxs for dev/test."
    }
}

# Vendored Jupyter wheelhouse. Staged as a directory rather than listed in
# commandfiles: assets/* entries flatten to the staging root, and 118 wheels at
# the root would bury the module's scripts. requirements.txt IS a commandfile, so
# the lock -- the declaration of what gets installed -- is inside the module
# content hash and drives drift; the wheels are its materialization (#133).
if (${Modules} -contains 'jupyter') {
    ${whSrc} = Join-Path ${providersRoot} 'jupyter\assets\wheels'
    ${whFiles} = @()
    if (Test-Path -LiteralPath ${whSrc}) {
        ${whFiles} = @(Get-ChildItem -LiteralPath ${whSrc} -Filter '*.whl' -File -ErrorAction SilentlyContinue)
    }
    if (${whFiles}.Count -gt 0) {
        ${whDst} = Join-Path ${staging} 'wheels'
        New-Item -ItemType Directory -Force -Path ${whDst} | Out-Null
        Copy-Item -Force -Path (Join-Path ${whSrc} '*.whl') -Destination ${whDst}
        Write-Host (" Staged Jupyter wheelhouse ({0} wheels, {1:N0} MB) -> {2}" -f ${whFiles}.Count, ((${whFiles} | Measure-Object -Property Length -Sum).Sum / 1MB), ${whDst})
    } else {
        throw "Jupyter wheelhouse is empty under '${whSrc}'. The provider installs with --no-index and cannot fall back to PyPI; regenerate with 'pip download -r assets/requirements.txt -d assets/wheels --only-binary=:all:' on a Windows host running the fleet's Python."
    }
}

# Astrometry index seed + smoke FITS. Sourced from C:\MAST\ on the build host
# ("use these paths for now") -- both are far too large to keep in the repo. We
# now stage the index FITS files themselves (the "seed"), NOT a pre-baked image:
# the imdisk provider builds a sparse 32 GB NTFS image on the unit and seeds it
# with these files (see server/providers/imdisk/provide-imdisk.ps1). The seed
# directory is populated once on the build host from the legacy 15 GB image via
# build/extract-index-seed.ps1. The smoke FITS is the solve input placed by the
# astrometry provider. These are required for a VALID run: without them the
# astrometry + mast-validation stages FAIL (the skip paths were removed), so we
# warn loudly at build time but do not hard-block the build itself.
${astroIndexSeedSrc} = 'C:\MAST\mast-indexes'
${fullFrameFitsSrc}  = 'C:\MAST\full-frame.fits'
if (${Modules} -contains 'imdisk') {
    if (Test-Path -LiteralPath ${astroIndexSeedSrc}) {
        ${seedFiles} = @(Get-ChildItem -LiteralPath ${astroIndexSeedSrc} -File -Recurse -ErrorAction SilentlyContinue)
        ${seedGb}    = ((${seedFiles} | Measure-Object Length -Sum).Sum / 1GB)
        New-LinkOrCopy -Target ${astroIndexSeedSrc} -LinkPath (Join-Path ${staging} 'mast-indexes')
        Write-Host (" Staged astrometry index seed: mast-indexes\ ({0} files, {1:N1} GB); the unit builds the sparse 32 GB image." -f ${seedFiles}.Count, ${seedGb})
    } else {
        Write-Warning ("Astrometry index seed missing at {0}; run build/extract-index-seed.ps1 once to populate it from the legacy 15 GB image. imdisk will have nothing to seed and astrometry/mast-validation will FAIL on the unit." -f ${astroIndexSeedSrc})
    }
}
if ((${Modules} -contains 'astrometry') -or (${Modules} -contains 'mast-validation')) {
    if (Test-Path -LiteralPath ${fullFrameFitsSrc}) {
        New-LinkOrCopy -Target ${fullFrameFitsSrc} -LinkPath (Join-Path ${staging} 'full-frame.fits')
        Write-Host (" Staged smoke FITS: full-frame.fits ({0:N1} MB)" -f ((Get-Item ${fullFrameFitsSrc}).Length / 1MB))
    } else {
        Write-Warning ("Smoke FITS missing at {0}; astrometry + mast-validation will FAIL on the unit." -f ${fullFrameFitsSrc})
    }
}

# PlaneWave PlateSolve3 catalog (real UCAC4/Orca). Like the astrometry index seed,
# the vendor files are far too large to keep in the repo, so they are sourced from
# C:\MAST\ps3-catalog on the build host and staged into the payload beside the
# planewave provider scripts. The provider (provide-planewave.ps1) runs the Inno
# installer silently against them. Both files must be staged together and keep
# their exact names -- the .bin is the installer's data payload and must sit beside
# the .exe. Without them 'ps3cli --server' cannot boot (no catalog) and the
# planewave verify FAILS, so warn loudly at build time but do not hard-block.
${ps3CatalogSrcDir}   = 'C:\MAST\ps3-catalog'
${ps3CatalogExeSrc}   = Join-Path ${ps3CatalogSrcDir} 'Setup_PlateSolve3_Catalog.exe'
${ps3CatalogDataSrc}  = Join-Path ${ps3CatalogSrcDir} 'Setup_PlateSolve3_Catalog-1.bin'
if (${Modules} -contains 'planewave') {
    if ((Test-Path -LiteralPath ${ps3CatalogExeSrc}) -and (Test-Path -LiteralPath ${ps3CatalogDataSrc})) {
        New-LinkOrCopy -Target ${ps3CatalogExeSrc}  -LinkPath (Join-Path ${staging} 'Setup_PlateSolve3_Catalog.exe')
        New-LinkOrCopy -Target ${ps3CatalogDataSrc} -LinkPath (Join-Path ${staging} 'Setup_PlateSolve3_Catalog-1.bin')
        Write-Host (" Staged PlateSolve3 catalog installer + data ({0:N1} GB)." -f ((Get-Item ${ps3CatalogDataSrc}).Length / 1GB))
    } else {
        Write-Warning ("PlateSolve3 catalog vendor files missing under {0} (need Setup_PlateSolve3_Catalog.exe + Setup_PlateSolve3_Catalog-1.bin); download them from planewave.com once. 'ps3cli --server' will have no catalog and the planewave verify will FAIL on the unit." -f ${ps3CatalogSrcDir})
    }
}

# Frozen Cygwin package cache (astrometry-dependencies). Like the astrometry
# index seed, it is build-host-vendored (binary, ~174 MB, not in git) and
# staged into the payload here. provide-astrometry-dependencies.ps1 installs
# from it FULLY OFFLINE (setup-x86_64.exe --local-install) so the installed
# cygwin is deterministic (3.6.9, matching the bundled fitsio wheel tag) and
# has no live-mirror dependency -- the itefix mirror is rolling and moving
# past 3.6.9 broke the pinned wheel (issue #20). Populate once per build host
# via build/harvest-cygwin-cache.ps1 (harvests a working unit's own cache).
${cygCacheSrc} = 'C:\MAST\cygwin-pkg-cache'
if (${Modules} -contains 'astrometry-dependencies') {
    ${cygCacheIni} = @()
    if (Test-Path -LiteralPath ${cygCacheSrc}) {
        ${cygCacheIni} = @(Get-ChildItem -LiteralPath ${cygCacheSrc} -Filter 'setup.ini' -File -Recurse -ErrorAction SilentlyContinue)
    }
    if (${cygCacheIni}.Count -gt 0) {
        ${cacheFiles} = @(Get-ChildItem -LiteralPath ${cygCacheSrc} -File -Recurse -ErrorAction SilentlyContinue)
        ${cacheMb}    = ((${cacheFiles} | Measure-Object Length -Sum).Sum / 1MB)
        New-LinkOrCopy -Target ${cygCacheSrc} -LinkPath (Join-Path ${staging} 'cygwin-pkg-cache')
        Write-Host (" Staged frozen cygwin package cache: cygwin-pkg-cache\ ({0} files, {1:N0} MB); astrometry-dependencies installs offline from it." -f ${cacheFiles}.Count, ${cacheMb})
    } elseif (${TestMode}) {
        Write-Warning ("Frozen cygwin package cache missing/invalid at {0}; run build/harvest-cygwin-cache.ps1 once to populate it. astrometry-dependencies will FAIL on the unit. Continuing due to -TestMode." -f ${cygCacheSrc})
    } else {
        throw ("Frozen cygwin package cache missing/invalid at {0} (need setup.ini under it). Run build/harvest-cygwin-cache.ps1 once to populate it from a working unit." -f ${cygCacheSrc})
    }
}

# emit commands.json
(${cmds} | Select-Object order,desc,cmd,module | ConvertTo-Json -Depth 6) | Out-File -FilePath (Join-Path ${staging} 'commands.json') -Encoding UTF8

# ---------------------------------------------------------------------------
# build-manifest.json - payload fingerprint for autonomous drift detection.
# Consumed by the driver to decide whether a unit needs an update,
# and copied to C:\MAST\installed-manifest.json on the unit by
# execute-mast-provisioning.ps1 once provisioning succeeds.
# Hash helpers (Get-PayloadHash, Get-ModuleContentHash) live in the
# dot-sourceable build-manifest-lib.ps1 so the Pester suite can exercise them
# without running a build.
# ---------------------------------------------------------------------------
. (Join-Path ${PSScriptRoot} 'build-manifest-lib.ps1')

function Get-GitSha {
    param([Parameter(Mandatory)][string]$RepoTop)
    try {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if (-not $git) { return $null }
        Push-Location $RepoTop
        try {
            $sha = (& git rev-parse HEAD 2>$null).Trim()
            if ($LASTEXITCODE -eq 0 -and $sha) { return $sha } else { return $null }
        } finally {
            Pop-Location
        }
    } catch {
        return $null
    }
}

${payloadHash} = Get-PayloadHash -StagingDir ${staging}
${gitSha}      = Get-GitSha -RepoTop ${Top}

# Per-module version + content hash from each provider's module.json. The
# 'version' field is required; a missing one is a build error (fail loud rather
# than emit a manifest with silent gaps). The literal string 'git' is
# substituted with the current git SHA so source-tracked modules (e.g. mast)
# report a meaningful hash. The content hash (Get-ModuleContentHash) covers the
# module's source commandfiles + its RESOLVED commands.json entries (provide +
# verify, with build-time injected args) + the resolved version -- see
# build-manifest-lib.ps1 and docs/per-module-tracking-plan.md.
# module_versions is kept alongside for existing consumers
# (tools/fleet-drift-report.py) and is deprecated: it duplicates
# module_state.<name>.version and goes away once the fleet report keys on
# module_state (per-module-tracking Stage 3).
${moduleState}    = [ordered]@{}
${moduleVersions} = [ordered]@{}
# Modules that must run on EVERY non-empty provisioning run, not only when they
# themselves drifted. These are the order-terminal cross-cutting providers --
# reboot (detect pending-reboot and drop the flag the orchestrator acts on),
# mast-services-finalize (the final operational step), proxy (the end-of-run
# posture re-assert). A targeted run that installed anything must still close
# with them, so the driver's per-module drift compare folds them into any
# non-empty target set. Declared per provider via module.json "always": true so
# the fact lives with the module, not in a list the driver has to keep in step.
${alwaysModules}  = @()
foreach (${vm} in ${Modules}) {
    ${vmf} = Read-ModuleManifest -ModuleName ${vm}
    if (${vmf}.PSObject.Properties.Match('always').Count -and ${vmf}.always) {
        ${alwaysModules} += ${vm}
    }
    if (-not ${vmf}.PSObject.Properties.Match('version').Count -or
        [string]::IsNullOrWhiteSpace(${vmf}.version)) {
        throw "module.json missing 'version' for module '${vm}'"
    }
    ${vstr} = [string]${vmf}.version
    if (${vstr} -eq 'git') { ${vstr} = ${gitSha} }
    ${moduleVersions}[${vm}] = ${vstr}

    ${vmCmdFiles} = @()
    if (${vmf}.commandfiles) { ${vmCmdFiles} = @(${vmf}.commandfiles | ForEach-Object { [string]$_ }) }
    ${vmCmds} = @(${cmds} |
        Where-Object { $_.module -eq ${vm} -or $_.module -eq (${vm} + '-verify') } |
        ForEach-Object { [string]$_.cmd })
    ${moduleState}[${vm}] = [ordered]@{
        version = ${vstr}
        hash    = Get-ModuleContentHash -ProviderDir (Join-Path ${providersRoot} ${vm}) `
                    -CommandFiles ${vmCmdFiles} -Commands ${vmCmds} -Version ([string]${vstr}) `
                    -RepoTop ${Top} -RepoFiles (Get-MastModuleRepoFiles -Manifest ${vmf})
    }
}

${manifest}    = [pscustomobject]@{
    built_at        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    git_sha         = ${gitSha}
    payload_hash    = ${payloadHash}
    hostname        = ${HostName}
    modules         = ${Modules}
    module_state    = ${moduleState}
    module_versions = ${moduleVersions}
    always_modules  = @(${alwaysModules})
}
(${manifest} | ConvertTo-Json -Depth 4) |
    Out-File -FilePath (Join-Path ${staging} 'build-manifest.json') -Encoding UTF8
Write-Host "Wrote build-manifest.json (payload_hash=${payloadHash}, git_sha=${gitSha})"

Write-Host "Staged ${HostName} at ${staging}"

# save allocation CSV if we changed it
Save-AllocCsv -Path ${allocCsv} -Rows ${allocRows}

Write-Host "Build complete. SMB share setup is handled separately by server\setup-smb-share.ps1."
