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
${expected} = @(${Expect}.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })

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

# The old layout is a hard failure, not something to work around: the unit is
# unmigrated, and the autonomous loop must refuse it rather than half-update it
# (docs/mast-clone-adoption-plan.md stage 6).
if (Test-Path -LiteralPath 'C:\MAST\repos') {
    [void]${issues}.Add('legacy C:\MAST\repos still present -- unit not migrated to the mast-clone layout')
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

    # Current? Compare HEAD against the tracked upstream ref.
    ${head} = (& ${gitExe} -C ${repoDir} rev-parse HEAD 2>$null | Select-Object -First 1)
    ${upstream} = (& ${gitExe} -C ${repoDir} rev-parse '@{u}' 2>$null | Select-Object -First 1)
    if (-not ${upstream}) {
        W ("no upstream ref for {0} (never fetched?); HEAD={1}" -f ${d}, ${head})
    } elseif (${head} -ne ${upstream}) {
        [void]${issues}.Add(("{0} differs from its branch: HEAD={1} upstream={2}" -f ${d}, ${head}, ${upstream}))
    } else {
        W ("{0}: current at {1}" -f ${d}, ${head})
    }
}

# Dependency currency: every pinned requirement installed at its pin. This is
# the check a presence-only verify could not make.
if (Test-Path -LiteralPath ${venvPython}) {
    ${frozen} = @{}
    foreach (${line} in (& ${venvPython} -m pip freeze 2>$null)) {
        if (${line} -match '^([^=<>!~ ]+)==(.+)$') {
            ${frozen}[${Matches}[1].Trim().ToLowerInvariant()] = ${Matches}[2].Trim()
        }
    }
    if (${frozen}.Count -eq 0) {
        [void]${issues}.Add('pip freeze returned nothing -- venv unusable?')
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
                ${name} = ${Matches}[1].ToLowerInvariant()
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

${svc} = Get-Service -Name 'mast-unit' -ErrorAction SilentlyContinue
if ($null -eq ${svc}) {
    [void]${issues}.Add('mast-unit service not registered')
} elseif (${svc}.Status -ne 'Running') {
    [void]${issues}.Add(("mast-unit service registered but not running (status={0})" -f ${svc}.Status))
}

if (${issues}.Count -gt 0) {
    (${issues} -join [Environment]::NewLine) | Out-File -FilePath ${verifyLog} -Append -Encoding UTF8
    if (Test-Path -LiteralPath ${smokeFile}) {
        Remove-Item -LiteralPath ${smokeFile} -Force -ErrorAction SilentlyContinue
    }
    Write-Host ("mast-verify FAILED: {0}" -f (${issues} -join '; '))
    exit 1
}

Set-Content -Path ${smokeFile} -Value 'mast_ok' -Encoding UTF8
W ("mast verify ok: {0} clone(s) current under {1}" -f ${expected}.Count, ${Top})
Write-Host 'mast-verify OK'
exit 0
