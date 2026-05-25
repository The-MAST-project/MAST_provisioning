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

Export-ModuleMember -Function @('Get-AllProviderModules')
