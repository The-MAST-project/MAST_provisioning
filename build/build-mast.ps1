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
  [string[]]${Modules} = @(
    'ascom',
    'chrome',
    'cygwin',
    'diagnostics',
    'git',
    'mast',
    'mongodb-client',
    'nomachine',
    'nssm',
    'phd2',
    'planewave',
    'python',
    'stage',
    'sysinternals',
    'vcredist2013',
    'vscode',
    'wireshark',
    'zwo'
    ), # your module order
  # Dev/test: allow missing NoMachine license files (skip staging nomachine.lic).
  [switch]${AllowMissingNoMachineLicense},
  # Dev/test: allow missing GitHub token file (skip staging mast_github.txt).
  [switch]${AllowMissingGithubToken},
  # Dev/test: allow missing large optional assets (skip with warning).
  [switch]${TestMode}
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

# Return $true if the commandfiles entry is under assets/
# function Test-IsAssetEntry {
#     param([Parameter(Mandatory)][string]$RelativePath)
#     $norm = $RelativePath -replace '\\','/'
#     return $norm.StartsWith('assets/', [System.StringComparison]::OrdinalIgnoreCase)
# }

# Copy an entry (file or directory) from module root to common cache
# function Sync-Entry-ToCommon {
#     param([Parameter(Mandatory)][string]$ModuleRoot,
#           [Parameter(Mandatory)][string]$RelativePath,
#           [Parameter(Mandatory)][string]$CommonModuleRoot)

#     $src = Join-Path $ModuleRoot $RelativePath
#     $dst = Join-Path $CommonModuleRoot $RelativePath
#     $dstDir = Split-Path $dst -Parent
#     New-Item -ItemType Directory -Force -Path $dstDir | Out-Null

#     if (Test-Path $src -PathType Container) {
#         robocopy "$src" "$dst" /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
#     } else {
#         Copy-Item -Force $src $dst
#     }
# }

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

# Sync all ASSET entries from module.json into common cache (once)
# function Sync-ModuleAssetsToCommonFromManifest {
#     param([Parameter(Mandatory)][string]$providersRoot,
#           [Parameter(Mandatory)][string]$ModuleName,
#           [Parameter(Mandatory)][string]$CommonAssetsRoot)

#     $mf         = Read-ModuleManifest -providersRoot $providersRoot -ModuleName $ModuleName
#     $moduleRoot = Join-Path $providersRoot $ModuleName
#     $commonMod  = Join-Path $CommonAssetsRoot $ModuleName

#     foreach ($rel in $mf.commandfiles) {
#         if (Test-IsAssetEntry -RelativePath $rel) {
#             Sync-Entry-ToCommon -ModuleRoot $moduleRoot -RelativePath $rel -CommonModuleRoot $commonMod
#         }
#     }
# }

# Stage a module from manifest: copy non-assets; link assets from common; optional filter for specific files
# function Stage-ModuleFromManifest {
#     param([Parameter(Mandatory)][string]$providersRoot,
#           [Parameter(Mandatory)][string]$ModuleName,
#           [Parameter(Mandatory)][string]$CommonAssetsRoot,
#           [Parameter(Mandatory)][string]$StagingRoot,
#           [string[]]$OnlyTheseAssetFiles)  # optional: whitelist specific asset files relative to assets/...

#     $mf         = Read-ModuleManifest -providersRoot $providersRoot -ModuleName $ModuleName
#     $moduleRoot = Join-Path $providersRoot $ModuleName
#     $commonMod  = Join-Path $CommonAssetsRoot $ModuleName

#     foreach ($rel in $mf.commandfiles) {
#         $srcFromModule = Join-Path $moduleRoot $rel
#         if (Test-IsAssetEntry -RelativePath $rel) {
#             # If a whitelist is provided, skip asset entries that are not in it
#             $relNorm = ($rel -replace '\\','/')

#             $isFolder = Test-Path $srcFromModule -PathType Container
#             $okay = $true
#             if ($OnlyTheseAssetFiles -and -not $isFolder) {
#                 # compare against 'assets/...' style
#                 $okay = $OnlyTheseAssetFiles -contains $relNorm
#             }
#             if (-not $okay) { continue }

#             $srcInCommon = Join-Path $commonMod $rel
#             $dstInStage  = Join-Path $StagingRoot $rel
#             New-LinkOrCopy -Target $srcInCommon -LinkPath $dstInStage
#         } else {
#             # Non-asset -> copy (scripts, etc.)
#             $dst = Join-Path $StagingRoot $rel
#             $dstDir = Split-Path $dst -Parent
#             New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
#             if (Test-Path $srcFromModule -PathType Container) {
#                 robocopy "$srcFromModule" "$dst" /E /NFL /NDL /NJH /NJS /NP | Out-Null
#             } else {
#                 Copy-Item -Force $srcFromModule $dst
#             }
#         }
#     }
# }


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

# Build commands list once (same for all), then tweak per host only if we add a SingleLicensePath
function Generate-Commands([string[]]${Mods}) {
  ${cmds}=@()
  foreach (${m} in ${Mods}) {
    ${mf}=Read-ModuleManifest -ModuleName ${m}

    # base command from manifest
    ${cmd} = [string]${mf}.command

    ${cmds} += [pscustomobject]@{ order = [int]${mf}.order; desc = [string]${mf}.description; cmd = ${cmd}; module = ${m} }

    if (${mf}.verify) {
      ${cmds} += [pscustomobject]@{ order = [int](${mf}.order + 1); desc = "[verify] " + [string]${mf}.name; cmd = [string]${mf}.verify; module="${m}-verify" }
    }
  }
  return (${cmds} | Sort-Object order, desc)
}

${baseCmds} = Generate-Commands -Mods ${Modules}

${stagingTop} = Join-Path ${OutRoot} ${HostName}
New-Item -ItemType Directory -Force -Path ${stagingTop} | Out-Null

${clientRoot} = Join-Path ${Top} 'client'
# Preparations
${staging} = Join-Path ${stagingTop} "00-preparation"
New-Item -ItemType Directory -Force -Path ${staging} | Out-Null
${prepScript} = Join-Path ${clientRoot} 'prepare-mast-client.ps1'
if (Test-Path ${prepScript}) {
    Copy-Item -Force ${prepScript} (Join-Path ${staging} 'prepare-mast-client.ps1')
    Write-Host " Staged prepare-mast-client.ps1"
} else {
    Write-Warning " prepare-mast-client.ps1 not found - skipping"
}
Write-Host "Populating preparation stage ${staging} ..."

# Actual provisioning
${staging} = Join-Path ${stagingTop} "01-provisioning"
New-Item -ItemType Directory -Force -Path ${staging} | Out-Null
Write-Host "Populating provisioning stage ${staging} ..."

# Always place provisioning.psm1 into staging
Copy-Item -Force ${serverLib} (Join-Path ${staging} 'provisioning.psm1')
${mastLogLib} = Join-Path (Split-Path -Parent ${serverLib}) 'mast-log.ps1'
if (-not (Test-Path ${mastLogLib})) { throw "Missing mast-log.ps1 at ${mastLogLib}" }
Copy-Item -Force ${mastLogLib} (Join-Path ${staging} 'mast-log.ps1')

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
${manifest}    = [pscustomobject]@{
    built_at     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    git_sha      = ${gitSha}
    payload_hash = ${payloadHash}
    hostname     = ${HostName}
    modules      = ${Modules}
}
(${manifest} | ConvertTo-Json -Depth 4) |
    Out-File -FilePath (Join-Path ${staging} 'build-manifest.json') -Encoding UTF8
Write-Host "Wrote build-manifest.json (payload_hash=${payloadHash}, git_sha=${gitSha})"

Write-Host "Staged ${HostName} at ${staging}"

# save allocation CSV if we changed it
Save-AllocCsv -Path ${allocCsv} -Rows ${allocRows}

Write-Host "Build complete. SMB share setup is handled separately by server\setup-smb-share.ps1."
