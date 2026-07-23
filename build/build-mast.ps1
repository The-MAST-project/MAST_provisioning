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
  # Dev/test: allow missing GitHub token file (skip staging mast_github.txt).
  [switch]${AllowMissingGithubToken},
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
  # becomes the unit's C:\WIS\unit.toml via the config-bootstrap provider. Selected
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
try { ${freeBytes} = (Get-PSDrive -Name (${OutDrive}.TrimEnd(':')) -ErrorAction Stop).Free } catch { }
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
# bootstrap script (client/bootstrap-winrm.ps1) cannot read that directory -- it
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
  ${bootstrapScript} = Join-Path ${ClientRoot} 'bootstrap-winrm.ps1'
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
    ${msg} = 'bootstrap-winrm.ps1 $knownSites is out of sync with config-bootstrap/sites/.'
    if (${missing}.Count -gt 0) { ${msg} += (' Missing from $knownSites: {0}.' -f (${missing} -join ', ')) }
    if (${extra}.Count -gt 0)   { ${msg} += (' In $knownSites but no matching sites/*.toml: {0}.' -f (${extra} -join ', ')) }
    ${msg} += (' Configured sites: {0}. Update the $knownSites list in {1} to match.' -f (${configured} -join ', '), ${bootstrapScript})
    throw ${msg}
  }
  Write-Host ('[build-mast] Site list in sync: {0} (bootstrap-winrm.ps1 $knownSites matches config-bootstrap/sites/).' -f (${configured} -join ', '))
}

Assert-BootstrapKnownSitesInSync -ClientRoot ${clientRoot} -ProvidersRoot ${providersRoot}

# If no -Modules were passed (or the normalization above collapsed to empty),
# default to the providers discovered on disk. Get-AllProviderModules lives in
# server/lib/mast-modules.psm1 (no admin required) so build-mast can call it
# even when running non-elevated; check-and-provision.ps1 imports the same
# module so both use the single source of truth.
if ($null -eq ${Modules} -or ${Modules}.Count -eq 0) {
    ${Modules} = Get-AllProviderModules -ProvidersRoot ${providersRoot}
    Write-Host ("Modules defaulted to {0} providers discovered under {1}." -f ${Modules}.Count, ${providersRoot})
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
        try { cmd /c "mklink /J `"$LinkPath`" `"$Target`"" | Out-Null; return } catch {}
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
        } catch {}
    }

    # Try symlink
    try {
        if ($isDir) {
            New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target -Force | Out-Null
        } else {
            New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target -Force | Out-Null
        }
        return
    } catch {}

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
function Load-AllocCsv([string]${Path}) {
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
${allocRows} = Load-AllocCsv ${allocCsv}

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
function Generate-Commands([string[]]${Mods}) {
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
      'imdisk' {
        if (${ImdiskMountType} -ne 'vm') {
          ${cmd} = ${cmd} + (" -MountType {0}" -f ${ImdiskMountType})
        }
      }
      'config-bootstrap' {
        # Inject the explicitly-selected -Site so the provider deploys
        # sites/<Site>.toml as C:\WIS\unit.toml. Fail the build early with a
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

${baseCmds} = Generate-Commands -Mods ${Modules}

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

${clientUtilScript} = Join-Path ${clientRoot} 'mast-client-util.ps1'
if (Test-Path ${clientUtilScript}) {
    Copy-Item -Force ${clientUtilScript} (Join-Path ${staging} 'mast-client-util.ps1')
    Write-Host " Staged mast-client-util.ps1"
} else {
    Write-Warning "mast-client-util.ps1 not found at ${clientUtilScript}"
}

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
            # mast_github.txt is sourced from vault/ and staged separately
            ($m -eq 'mast' -and $norm -eq 'assets/mast_github.txt')
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
}


# clone base commands; optionally inject a per-host license into the nomachine command
${cmds} = ${baseCmds}

if (${Modules} -contains 'nomachine') {
    # do we already have a license for this host?
    ${existing} = ${allocRows} | Where-Object { $_.host -ieq ${HostName} } | Select-Object -First 1
    if (${existing}) {
        $licPath = Join-Path ${LicensesRoot} ${existing}.license
        if (Test-Path $licPath) {
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
            ${allocRows} += [pscustomobject]@{ license=${free}.Name; host=${HostName} }
            # stage that single .lic
            Copy-Item -Force ${free}.FullName (Join-Path ${staging} "nomachine.lic")
        }
    }
}

if (${Modules} -contains 'mast') {
    # deploy the github token (used by the mast module)
    $tokenPath = Join-Path ${vault} 'tokens\mast_github.txt'
    if (Test-Path $tokenPath) {
        Copy-Item -Force -Path $tokenPath (Join-Path ${staging} 'mast_github.txt')
    } elseif (${AllowMissingGithubToken}) {
        Write-Warning "GitHub token '$tokenPath' missing; continuing due to -AllowMissingGithubToken."
    } else {
        throw "GitHub token '$tokenPath' missing. Create it or pass -AllowMissingGithubToken for dev/test."
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
    ${sxsCabs} = @()
    if (Test-Path -LiteralPath ${sxsSrc}) {
        ${sxsCabs} = @(Get-ChildItem -LiteralPath ${sxsSrc} -Filter '*.cab' -File -Recurse -ErrorAction SilentlyContinue)
    }
    if (${sxsCabs}.Count -gt 0) {
        # Stage the whole sxs\ subtree under the ascom staging area; the
        # provider points DISM at this path via -FoDSource.
        ${sxsDst} = Join-Path ${staging} 'sxs'
        New-Item -ItemType Directory -Force -Path ${sxsDst} | Out-Null
        Copy-Item -Force -Recurse -Path (Join-Path ${sxsSrc} '*') -Destination ${sxsDst}
        Write-Host (" Staged NetFx3 SxS source ({0} .cab file(s)) -> {1}" -f ${sxsCabs}.Count, ${sxsDst})
    } elseif (${AllowMissingNetFx3Sxs}) {
        Write-Warning "NetFx3 SxS source under '$sxsSrc' is empty; continuing due to -AllowMissingNetFx3Sxs (provider will fall back to online DISM)."
    } else {
        throw "NetFx3 SxS source missing under '$sxsSrc'. Drop the Windows IoT 11 LTSC SxS files there (see provider README), or pass -AllowMissingNetFx3Sxs for dev/test."
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
# Consumed by check-and-provision.ps1 to decide whether a unit needs an update,
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
foreach (${vm} in ${Modules}) {
    ${vmf} = Read-ModuleManifest -ModuleName ${vm}
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
                    -CommandFiles ${vmCmdFiles} -Commands ${vmCmds} -Version ([string]${vstr})
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
}
(${manifest} | ConvertTo-Json -Depth 4) |
    Out-File -FilePath (Join-Path ${staging} 'build-manifest.json') -Encoding UTF8
Write-Host "Wrote build-manifest.json (payload_hash=${payloadHash}, git_sha=${gitSha})"

Write-Host "Staged ${HostName} at ${staging}"

# save allocation CSV if we changed it
Save-AllocCsv -Path ${allocCsv} -Rows ${allocRows}

Write-Host "Build complete. SMB share setup is handled separately by server\setup-smb-share.ps1."
