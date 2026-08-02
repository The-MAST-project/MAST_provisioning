#requires -RunAsAdministrator
<#
.SYNOPSIS
  Lay down the MAST source tree for the 'unit' role and register the mast-unit service.

.DESCRIPTION
  Cloning, branch pinning, venv creation and dependency installation are NOT done
  here: they are delegated to tools/mast-clone.ps1, the same script the control
  host and dev boxes use, staged into the payload as a 'repofiles' entry. One
  implementation of "lay out the MAST repos and build their environment" for
  every machine in the fleet -- see docs/mast-clone-adoption-plan.md, issue #31.

  What stays here is the part mast-clone does not do:
    - ensure Git for Windows is present (mast-clone requires git on PATH);
    - register the mast-unit NSSM service against the resulting layout;
    - open the unit API firewall port;
    - restart the service when the unit checkout actually moved.

  Layout produced by mast-clone -Role unit under -Top:

    <Top>\
      .venv\      ONE venv for the role (uv, version pinned by mast-repos.tsv)
      common\     MAST_common -- the repo root IS the 'common' package
      unit\       MAST_unit.2024-12-12
      claude\     mast-claude-config

  <Top> is put on sys.path by a mast.pth that mast-clone writes into the venv, so
  the unit's existing 'from common.X import ...' resolves with no source edits and
  no submodule.

.PARAMETER Top
  Root of the MAST source tree. Default C:\MAST\src -- a sibling of the C:\MAST
  state tree (logs, manifests, smoke markers), and the path baked into the
  mast-unit service definition.

.PARAMETER Force
  Remove <Top> entirely and rebuild from scratch (stopping mast-unit first).
  Without it an existing tree is fetched and fast-forwarded in place.
#>
[CmdletBinding()]
param(
    [string]${AssetsRoot} = ${PSScriptRoot},
    [string]${Top}        = 'C:\MAST\src',
    [switch]${Force}
)

# Import shared helpers
try {
    ${provLocal}  = Join-Path ${PSScriptRoot} 'provisioning.psm1'
    ${provGlobal} = 'C:\ProgramData\MAST\provisioning.psm1'
    if (Test-Path ${provLocal}) {
        Import-Module ${provLocal} -Force -DisableNameChecking
    } elseif (Test-Path ${provGlobal}) {
        Import-Module ${provGlobal} -Force -DisableNameChecking
    } else {
        throw "provisioning.psm1 not found."
    }
}
catch {
    throw "Failed to import provisioning.psm1: $($_.Exception.Message)"
}

# Staged flat into the payload root as a 'repofiles' entry of this module, so it
# sits beside this script at run time (see build/build-staging-lib.ps1).
${MastCloneScript} = Join-Path ${PSScriptRoot} 'mast-clone.ps1'
if (-not (Test-Path -LiteralPath ${MastCloneScript})) {
    throw ("mast-clone.ps1 not found at {0}. It is staged as a 'repofiles' entry of the mast module; see build-mast.ps1." -f ${MastCloneScript})
}

# The role this provider provisions. mast-clone resolves it against
# tools/mast-repos.tsv, the single source of truth for which repos and branches a
# role gets -- this script deliberately holds no repo list of its own.
${MastRole}     = 'unit'
${ServiceName}  = 'mast-unit'
${UnitDirName}  = 'unit'
${FirewallRule} = 'MAST - Unit API (TCP 8000)'
${UnitApiPort}  = 8000

function Update-MastProcessPathFromRegistry {
    ${machinePath} = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    ${userPath} = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (${machinePath} -and ${userPath}) {
        ${env:Path} = ${machinePath} + ';' + ${userPath}
    } elseif (${machinePath}) {
        ${env:Path} = ${machinePath}
    } elseif (${userPath}) {
        ${env:Path} = ${userPath}
    }
}

function Resolve-MastGitExe {
    ${candidates} = @(
        'C:\Program Files\Git\cmd\git.exe',
        'C:\Program Files\Git\bin\git.exe',
        'C:\Program Files (x86)\Git\cmd\git.exe',
        'C:\Program Files (x86)\Git\bin\git.exe'
    )
    foreach (${c} in ${candidates}) {
        if (Test-Path -LiteralPath ${c}) { return ${c} }
    }
    Update-MastProcessPathFromRegistry
    ${cmdObj} = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (${cmdObj} -and (Test-Path -LiteralPath ${cmdObj}.Source)) {
        return ${cmdObj}.Source
    }
    foreach (${c} in ${candidates}) {
        if (Test-Path -LiteralPath ${c}) { return ${c} }
    }
    return $null
}

function Write-MastProvisionEvent {
    param([Parameter(Mandatory)][string]${Message})
    ${ts} = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    Write-Host ("[{0}] [provide-mast] {1}" -f ${ts}, ${Message})
}

function Get-MastRepoHead {
    # HEAD of a clone, or '' when absent. Used to decide whether the unit
    # checkout actually moved, so the service restarts on a real update rather
    # than on every cycle.
    param([Parameter(Mandatory)][string]${GitExe}, [Parameter(Mandatory)][string]${RepoDir})
    if (-not (Test-Path -LiteralPath (Join-Path ${RepoDir} '.git'))) { return '' }
    ${out} = & ${GitExe} -C ${RepoDir} rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not ${out}) { return '' }
    return ([string](@(${out})[0])).Trim()
}

${log} = Start-ProvisionLog -Component 'provide-mast'
try {
    # --- Git (mast-clone requires it on PATH) ------------------------------
    ${gitExe} = Resolve-MastGitExe
    if (-not ${gitExe}) {
        ${installerPath} = Join-Path ${AssetsRoot} "Git-2.52.0-64-bit.exe"
        if (-not (Test-Path ${installerPath})) {
            throw "Git installer not found at ${installerPath}. Add Git for Windows to assets or preinstall Git; VS Code does not install Git to C:\Program Files\Git."
        }
        & ${installerPath} /VERYSILENT
        Start-Sleep -Seconds 3
        Update-MastProcessPathFromRegistry
        ${gitExe} = Resolve-MastGitExe
    }
    if (-not ${gitExe}) {
        throw ("Git not found after silent install. Confirm Git for Windows completed or add git.exe to PATH. Asset: {0}" -f (Join-Path ${AssetsRoot} "Git-2.52.0-64-bit.exe"))
    }
    Write-MastProvisionEvent ("Using Git at: {0}" -f ${gitExe})

    ${unitDir} = Join-Path ${Top} ${UnitDirName}

    # --- Force: rebuild the tree from scratch ------------------------------
    if (${Force} -and (Test-Path -LiteralPath ${Top})) {
        ${svcForce} = Get-Service -Name ${ServiceName} -ErrorAction SilentlyContinue
        if (${svcForce} -and ${svcForce}.Status -eq 'Running') {
            Write-MastProvisionEvent ("Force: stopping {0} before removing {1}" -f ${ServiceName}, ${Top})
            Stop-Service -Name ${ServiceName} -Force -ErrorAction SilentlyContinue
        }
        Write-MastProvisionEvent ("Force: removing {0}" -f ${Top})
        Remove-Item -LiteralPath ${Top} -Recurse -Force -ErrorAction SilentlyContinue
    }

    ${headBefore} = Get-MastRepoHead -GitExe ${gitExe} -RepoDir ${unitDir}

    # --- Delegate clone + venv + dependency install ------------------------
    # -Transport https: a unit has no SSH key material for GitHub, and every
    #   The-MAST-project repo is public, so this needs no credential (issue #17).
    # -Update: fast-forward existing clones. mast-clone refuses to merge over a
    #   dirty tree rather than discarding local work; verify-mast.ps1 reports such
    #   a unit as failed, so a silently-frozen checkout cannot pass unnoticed.
    Write-MastProvisionEvent ("mast-clone BEGIN top={0} role={1}" -f ${Top}, ${MastRole})
    ${sw} = [System.Diagnostics.Stopwatch]::StartNew()
    & ${MastCloneScript} -Top ${Top} -Role ${MastRole} -Transport https -Update
    ${rc} = $LASTEXITCODE
    ${sw}.Stop()
    Write-MastProvisionEvent ("mast-clone END elapsedSec={0:N1} exitCode={1}" -f ${sw}.Elapsed.TotalSeconds, ${rc})
    if ($null -ne ${rc} -and ${rc} -ne 0) {
        throw ("mast-clone.ps1 failed with exit code {0}" -f ${rc})
    }

    ${venvPython} = Join-Path ${Top} '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath ${venvPython})) {
        throw ("mast-clone reported success but no venv interpreter at {0}" -f ${venvPython})
    }
    if (-not (Test-Path -LiteralPath ${unitDir})) {
        throw ("mast-clone reported success but no unit checkout at {0}" -f ${unitDir})
    }

    ${headAfter} = Get-MastRepoHead -GitExe ${gitExe} -RepoDir ${unitDir}
    ${unitMoved} = (${headBefore} -ne ${headAfter})
    ${headBeforeLabel} = if (${headBefore}) { ${headBefore} } else { 'none' }
    Write-MastProvisionEvent ("unit HEAD {0} -> {1} (moved={2})" -f ${headBeforeLabel}, ${headAfter}, ${unitMoved})

    # --- Register mast-unit as a Windows service via NSSM ------------------
    ${nssmExe} = 'C:\Program Files\nssm\nssm.exe'
    ${unitEntryPoint} = Join-Path ${unitDir} 'src\app.py'
    if (-not (Test-Path -LiteralPath ${nssmExe})) {
        Write-Warning "NSSM not found at ${nssmExe}; skipping mast-unit service registration."
    } elseif (-not (Test-Path -LiteralPath ${unitEntryPoint})) {
        Write-Warning ("mast-unit entry point not found at {0}; skipping service registration." -f ${unitEntryPoint})
    } else {
        ${existingSvc} = Get-Service -Name ${ServiceName} -ErrorAction SilentlyContinue
        if ($null -eq ${existingSvc}) {
            Write-MastProvisionEvent ("NSSM service register BEGIN name={0}" -f ${ServiceName})
            ${svcLogDir} = 'C:\MAST\logs\mast-unit'
            Confirm-Dir ${svcLogDir}
            & ${nssmExe} install ${ServiceName} ${venvPython} ${unitEntryPoint}
            & ${nssmExe} set ${ServiceName} AppDirectory ${unitDir}
            # MAST_PROJECT selects the role-based bootstrap config C:\WIS\<role>.toml
            # (MAST_common load_local_config). config-bootstrap (order 150) also sets
            # it machine-wide, which the service inherits on start; set it explicitly
            # here too so the service env is correct even on a re-provision.
            & ${nssmExe} set ${ServiceName} AppEnvironmentExtra 'MAST_PROJECT=unit'
            & ${nssmExe} set ${ServiceName} Start SERVICE_AUTO_START
            & ${nssmExe} set ${ServiceName} AppDependencies mast-pwi4
            & ${nssmExe} set ${ServiceName} AppStdout (Join-Path ${svcLogDir} 'stdout.log')
            & ${nssmExe} set ${ServiceName} AppStderr (Join-Path ${svcLogDir} 'stderr.log')
            & ${nssmExe} set ${ServiceName} AppRotateFiles 1
            & ${nssmExe} set ${ServiceName} AppRotateOnline 1
            & ${nssmExe} set ${ServiceName} AppRotateBytes 10485760
            if (-not (Get-NetFirewallRule -DisplayName ${FirewallRule} -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName ${FirewallRule} -Direction Inbound -Action Allow `
                    -Protocol TCP -LocalPort ${UnitApiPort} -Profile Any | Out-Null
                Write-MastProvisionEvent ("Firewall rule created: {0}" -f ${FirewallRule})
            } else {
                Write-MastProvisionEvent ("Firewall rule already exists: {0}" -f ${FirewallRule})
            }
            Start-Service -Name ${ServiceName} -ErrorAction SilentlyContinue
            Write-MastProvisionEvent ("NSSM service register DONE name={0}" -f ${ServiceName})
        } else {
            # An already-registered service on a pre-migration unit still points at
            # the OLD layout (C:\MAST\repos\MAST_unit.2024-12-12 with a per-repo
            # venv). Re-point it rather than leaving it running code from a tree the
            # migration is about to delete.
            ${curApp} = ((& ${nssmExe} get ${ServiceName} Application) -join '').Trim([char]0, ' ', "`r", "`n")
            if (${curApp} -and ${curApp} -ne ${venvPython}) {
                Write-MastProvisionEvent ("NSSM service re-point: {0} -> {1}" -f ${curApp}, ${venvPython})
                Stop-Service -Name ${ServiceName} -Force -ErrorAction SilentlyContinue
                & ${nssmExe} set ${ServiceName} Application ${venvPython}
                & ${nssmExe} set ${ServiceName} AppParameters ${unitEntryPoint}
                & ${nssmExe} set ${ServiceName} AppDirectory ${unitDir}
                Start-Service -Name ${ServiceName} -ErrorAction SilentlyContinue
            } elseif (${unitMoved} -or ${Force}) {
                Write-MastProvisionEvent ("Restarting {0} (unit checkout moved)" -f ${ServiceName})
                Restart-Service -Name ${ServiceName} -Force -ErrorAction SilentlyContinue
            } else {
                Write-MastProvisionEvent ("NSSM service SKIP (registered, unit unchanged) name={0}" -f ${ServiceName})
            }
        }
    }

    Write-MastProvisionEvent ("MAST source tree ready at {0}" -f ${Top})
}
finally {
    Stop-ProvisionLog
}
exit 0
