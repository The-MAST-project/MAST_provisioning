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

# The service must be REGISTERED and pointed at this layout's interpreter. Its
# run state deliberately is NOT checked here.
#
# mast-services-finalize (order 9500) sets every MAST service to Manual and
# STOPS it -- a deliberate current-development-stage measure so a provisioned
# unit does not auto-start telescope services on boot. The mast provider
# registers auto-start and starts the service so the per-provider verify steps
# run while it is alive; finalize then flips it. So on a fully-provisioned unit
# at rest mast-unit is Stopped BY DESIGN, and asserting 'Running' here would
# fail every correct unit -- and would put two providers in charge of one fact.
# finalize owns run state and has its own verify for Manual+Stopped.
#
# What IS this module's business is the interpreter the service runs, since that
# is exactly what the move to the mast-clone layout changes.
${svc} = Get-Service -Name 'mast-unit' -ErrorAction SilentlyContinue
if ($null -eq ${svc}) {
    [void]${issues}.Add('mast-unit service not registered')
} else {
    W ("mast-unit service: Status={0} StartType={1} (run state owned by mast-services-finalize)" -f ${svc}.Status, ${svc}.StartType)
    ${nssmExe} = 'C:\Program Files\nssm\nssm.exe'
    if (Test-Path -LiteralPath ${nssmExe}) {
        # nssm writes UTF-16LE, which arrives through the pipe as every character
        # followed by a NUL. Those NULs must be stripped, not trimmed: Trim only
        # touches the ends. And the comparison must be ORDINAL -- PowerShell's
        # default '-ne' is culture-sensitive and treats NUL as a zero-weight
        # character, so a NUL-laden path compares EQUAL to a clean one. This
        # check therefore used to pass by accident, and "fixing" it to ordinal
        # without stripping would have failed every unit instead (measured
        # 2026-08-03). Strip, then compare ordinally.
        ${svcApp} = (((& ${nssmExe} get mast-unit Application) -join '') -replace "`0", '').Trim()
        if (${svcApp} -and -not [string]::Equals(${svcApp}, ${venvPython}, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]${issues}.Add(("mast-unit runs {0}, expected {1} -- service not re-pointed at the mast-clone venv" -f ${svcApp}, ${venvPython}))
        } else {
            W ("mast-unit interpreter: {0}" -f ${svcApp})
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

Set-Content -Path ${smokeFile} -Value 'mast_ok' -Encoding UTF8
W ("mast verify ok: {0} clone(s) current under {1}" -f ${expected}.Count, ${Top})
Write-Host 'mast-verify OK'
exit 0
