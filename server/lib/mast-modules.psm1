Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Provider discovery (no admin required)
# ---------------------------------------------------------------------------
# Scan server/providers/*/module.json and return module names sorted by the
# 'order' field. This is the canonical "complete provider set" used as the
# default for -Modules across the project (build-mast.ps1, check-and-
# provision.ps1, vm/run-prov-test.py's Python equivalent).
#
# Lives in its own .psm1 (rather than provisioning.psm1) because build-mast.ps1
# may run non-elevated and provisioning.psm1 carries
# #Requires -RunAsAdministrator. Discovery is pure file-system reads, so this
# helper has no admin requirement.
#
# Robust to:
#   - module.json files written with a UTF-8 BOM (stripped before
#     ConvertFrom-Json; PS 5.1 Get-Content -Raw can leave it in place
#     depending on encoding parameter combinations).
#   - missing / non-integer 'order' (treated as 0).
#   - malformed JSON (skipped with Write-Warning, scan continues).

function Get-AllProviderModules {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]${ProvidersRoot}
  )
  if (-not (Test-Path ${ProvidersRoot})) {
    throw "Providers directory not found: ${ProvidersRoot}"
  }
  ${entries} = @()
  foreach (${dir} in Get-ChildItem -LiteralPath ${ProvidersRoot} -Directory) {
    ${mj} = Join-Path ${dir}.FullName 'module.json'
    if (-not (Test-Path ${mj})) { continue }
    try {
      ${raw} = Get-Content -LiteralPath ${mj} -Raw -Encoding UTF8
      if (${raw}.Length -gt 0 -and [int]${raw}[0] -eq 0xFEFF) {
        ${raw} = ${raw}.Substring(1)
      }
      ${data} = ${raw} | ConvertFrom-Json
    } catch {
      Write-Warning ("Skipping malformed {0}: {1}" -f ${mj}, $_.Exception.Message)
      continue
    }
    ${name} = if (${data}.name) { [string]${data}.name } else { ${dir}.Name }
    ${order} = 0
    try { ${order} = [int]${data}.order } catch { ${order} = 0 }
    ${entries} += [pscustomobject]@{ Name = ${name}; Order = ${order} }
  }
  if (${entries}.Count -eq 0) {
    throw "No providers discovered under ${ProvidersRoot} (check repo layout)."
  }
  return (${entries} | Sort-Object Order | ForEach-Object { $_.Name })
}

# ---------------------------------------------------------------------------
# Site discovery (no admin required)
# ---------------------------------------------------------------------------
# Scan server/providers/config-bootstrap/sites/*.toml and return the site codes
# (file base names, lower-cased, sorted). This is the canonical "known sites"
# set: adding sites/<code>.toml is the only step needed to define a new site.
# build-mast.ps1 validates -Site against it, and uses it to guard that the
# offline bootstrap script's embedded $knownSites list has not drifted.

function Get-ConfiguredSites {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]${ProvidersRoot}
  )
  ${sitesDir} = Join-Path ${ProvidersRoot} 'config-bootstrap\sites'
  if (-not (Test-Path ${sitesDir})) {
    throw "Site profiles directory not found: ${sitesDir}"
  }
  ${sites} = @(
    Get-ChildItem -LiteralPath ${sitesDir} -Filter '*.toml' -File -ErrorAction SilentlyContinue |
      ForEach-Object { ${_}.BaseName.ToLowerInvariant() } |
      Sort-Object
  )
  if (${sites}.Count -eq 0) {
    throw "No site profiles (*.toml) found under ${sitesDir}."
  }
  return ${sites}
}

# ---------------------------------------------------------------------------
# Fleet hardware requirement (no admin required)
# ---------------------------------------------------------------------------
# The memory a MAST unit must have, and the single declaration of it. The figure
# is not a preference: server/providers/imdisk mounts D: as a RAM-backed VOLATILE
# ImDisk (`imdisk -a -m D: -t vm`), and that attach commits the image's full
# 32 GB. 64 GB is that commit plus room for the control stack, the venvs and a
# solve running at the same time.
#
# Two consumers, one number:
#   - build-mast.ps1 injects it into the imdisk module command (-MinMemoryGB), so
#     a run that reaches the mount has already asserted the machine can host it.
#   - client/bootstrap-winrm.ps1 EMBEDS it ($script:RequiredMemoryGB), because it
#     runs offline on a bare unit and cannot import this module -- exactly the
#     $knownSites situation, and guarded the same way by
#     Assert-BootstrapMemoryRequirementInSync in build-mast.ps1.
#
# A fleet that ever stops being uniform needs a per-unit value here instead
# (unit-registry.json is where it would be declared); until then, one number.

function Get-MastRequiredMemoryGB {
  [CmdletBinding()]
  param()
  return 64
}

Export-ModuleMember -Function @('Get-AllProviderModules', 'Get-ConfiguredSites', 'Get-MastRequiredMemoryGB')
