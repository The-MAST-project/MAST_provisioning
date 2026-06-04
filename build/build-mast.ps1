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
  #   weizmann -> proxy provider gets -ForceMode use; astrometry-dependencies
  #               gets -ProxyMode use (passes --proxy bcproxy:8080 to setup.exe
  #               and writes setup.rc with net-method=Proxy).
  #   direct   -> proxy provider gets -ForceMode direct; astrometry-dependencies
  #               gets -ProxyMode direct (writes setup.rc with net-method=Direct
  #               so setup.exe skips IE5/WPAD discovery).
  # Default is 'weizmann' (the common on-campus case). Runs against a unit
  # that cannot reach bcproxy MUST override to 'direct' -- regardless of
  # whether the run is dev or prod; the deciding factor is purely the
  # unit's network reachability. `vm/run-prov-test.py --proxy-mode direct`
  # is the canonical way to do so. See DECISIONS.md 2026-05-26.
  [ValidateSet('weizmann','direct')]
  [string]${ProxyMode} = 'weizmann'
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
# A full staging payload is ~16-17 GB (dominated by the astrometry index image).
# Fail fast if the staging drive is low rather than writing a truncated payload
# that then breaks the unit-side pull (robocopy rc>=8) deep into a run.
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
[string]${LicensesRoot} = (Join-Path ${Top} 'vault\nomachine-licenses')
${licensesVault} = (Join-Path ${vault} 'nomachine-licenses')

# Read a module manifest: modules\<name>\module.json
function Read-ModuleManifest {
    param([Parameter(Mandatory)][string]$ModuleName)
    $path = Join-Path (Join-Path ${providersRoot} $ModuleName) 'module.json'
    if (-not (Test-Path $path)) { throw "Missing module.json for module '$ModuleName' at $path" }
    return Get-Content $path -Raw | ConvertFrom-Json
}

# If no -Modules were passed (or the normalization above collapsed to empty),
# default to the providers discovered on disk. Get-AllProviderModules lives in
# server/lib/mast-modules.psm1 (no admin required) so build-mast can call it
# even when running non-elevated; check-and-provision.ps1 imports the same
# module so both use the single source of truth.
if ($null -eq ${Modules} -or ${Modules}.Count -eq 0) {
    ${modulesLib} = Join-Path ${serverRoot} 'lib\mast-modules.psm1'
    if (-not (Test-Path ${modulesLib})) { throw "Missing mast-modules.psm1 at ${modulesLib}" }
    Import-Module ${modulesLib} -Force -DisableNameChecking
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
        try { cmd /c "mklink /H `"$LinkPath`" `"$Target`"" | Out-Null; return } catch {}
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
${astroDepProxyMode} = ${proxyForceMode}   # provide-astrometry-dependencies.ps1 uses identical naming

# Banner: print the chosen mode prominently so an operator scanning a build
# log can tell at a glance which mode this staging directory was built for.
${proxyBanner} = if (${ProxyMode} -eq 'weizmann') { '*** WEIZMANN-PROXY MODE ***' } else { '*** NO-WEIZMANN-PROXY (DIRECT) MODE ***' }
Write-Host "==================================================================="
Write-Host ("[build-mast] {0}" -f ${proxyBanner})
Write-Host ("[build-mast] proxy provider           -> -ForceMode {0}" -f ${proxyForceMode})
Write-Host ("[build-mast] astrometry-dependencies  -> -ProxyMode {0}" -f ${astroDepProxyMode})
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
      'astrometry-dependencies' {
        ${cmd} = ${cmd} + (" -ProxyMode {0}" -f ${astroDepProxyMode})
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

# Astrometry index image + smoke FITS. Sourced from C:\MAST\ on the build host
# ("use these paths for now") -- both are far too large to keep in the repo. The
# index image is mounted as D: by the imdisk provider (which copies it to the
# persistent C:\MAST\Shared path on the unit); the smoke FITS is the solve input
# placed by the astrometry provider. These are required for a VALID run: without
# them the astrometry + mast-validation stages FAIL (the skip paths were removed),
# so we warn loudly at build time but do not hard-block the build itself.
${astroIndexImageSrc} = 'C:\MAST\MAST-15GB-indexes-5202+5203.img'
${fullFrameFitsSrc}   = 'C:\MAST\full-frame.fits'
if (${Modules} -contains 'imdisk') {
    if (Test-Path -LiteralPath ${astroIndexImageSrc}) {
        ${imgLeaf} = Split-Path -Leaf ${astroIndexImageSrc}
        New-LinkOrCopy -Target ${astroIndexImageSrc} -LinkPath (Join-Path ${staging} ${imgLeaf})
        Write-Host (" Staged astrometry index image: {0} ({1:N1} GB)" -f ${imgLeaf}, ((Get-Item ${astroIndexImageSrc}).Length / 1GB))
    } else {
        Write-Warning ("Astrometry index image missing at {0}; imdisk will have nothing to mount and astrometry/mast-validation will FAIL on the unit." -f ${astroIndexImageSrc})
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

# emit commands.json
(${cmds} | Select-Object order,desc,cmd,module | ConvertTo-Json -Depth 6) | Out-File -FilePath (Join-Path ${staging} 'commands.json') -Encoding UTF8

# ---------------------------------------------------------------------------
# build-manifest.json - payload fingerprint for autonomous drift detection.
# Consumed by check-and-provision.ps1 to decide whether a unit needs an update,
# and copied to C:\MAST\installed-manifest.json on the unit by
# execute-mast-provisioning.ps1 once provisioning succeeds.
# ---------------------------------------------------------------------------
function Get-PayloadHash {
    param([Parameter(Mandatory)][string]$StagingDir)

    # Hash inputs: every regular file under the staging dir, in lexical order,
    # combining "<relative-path>:<sha256>" into a single rolling hash.
    # commands.json is included implicitly. build-manifest.json is excluded
    # (we are generating it now).
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.IO.MemoryStream]::new()
    $files = Get-ChildItem -Path $StagingDir -File -Recurse |
                Where-Object { $_.Name -ne 'build-manifest.json' } |
                Sort-Object FullName
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($StagingDir.Length).TrimStart('\','/').Replace('\','/')
        $fileHash = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $line = [System.Text.Encoding]::UTF8.GetBytes("$rel`:$fileHash`n")
        $bytes.Write($line, 0, $line.Length)
    }
    $bytes.Position = 0
    $digest = $sha.ComputeHash($bytes)
    return ([System.BitConverter]::ToString($digest) -replace '-','').ToLowerInvariant()
}

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

# Aggregate per-module versions from each provider's module.json. The 'version'
# field is required; a missing one is a build error (fail loud rather than emit
# a manifest with silent gaps). The literal string 'git' is substituted with the
# current git SHA so source-tracked modules (e.g. mast) report a meaningful hash.
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
}

${manifest}    = [pscustomobject]@{
    built_at        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    git_sha         = ${gitSha}
    payload_hash    = ${payloadHash}
    hostname        = ${HostName}
    modules         = ${Modules}
    module_versions = ${moduleVersions}
}
(${manifest} | ConvertTo-Json -Depth 4) |
    Out-File -FilePath (Join-Path ${staging} 'build-manifest.json') -Encoding UTF8
Write-Host "Wrote build-manifest.json (payload_hash=${payloadHash}, git_sha=${gitSha})"

Write-Host "Staged ${HostName} at ${staging}"

# save allocation CSV if we changed it
Save-AllocCsv -Path ${allocCsv} -Rows ${allocRows}

Write-Host "Build complete. SMB share setup is handled separately by server\setup-smb-share.ps1."
