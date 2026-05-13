#requires -Version 5.1
# Verify outcomes of provide-mast.ps1 (not only that CloneRoot exists).
# Repo list is read from mast-repos.txt (same file as provide-mast.ps1).
[CmdletBinding()]
param(
    [string]${CloneRoot} = 'C:\MAST\repos'
)

${mastRepoListScript} = Join-Path ${PSScriptRoot} 'mast-repo-list.ps1'
if (-not (Test-Path -LiteralPath ${mastRepoListScript})) {
    Write-Error "mast-repo-list.ps1 not found: ${mastRepoListScript}"
    exit 1
}
. ${mastRepoListScript}

${repoListPath} = Join-Path ${PSScriptRoot} 'mast-repos.txt'
try {
    ${repoSpecs} = Read-MastRepoSpecFile -Path ${repoListPath}
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

${logRoot} = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'logs'
${verifyLog} = Join-Path ${logRoot} 'verify\mast-verify.log'
${smokeFile} = Join-Path ${logRoot} 'smoke\mast-smoke.txt'

${issues} = New-Object 'System.Collections.Generic.List[string]'

if (-not (Test-Path -LiteralPath ${CloneRoot})) {
    [void]${issues}.Add("CloneRoot missing: ${CloneRoot}")
}

foreach (${spec} in ${repoSpecs}) {
    ${name} = Split-Path ${spec} -Leaf
    ${repoDir} = Join-Path ${CloneRoot} ${name}
    ${gitDir} = Join-Path ${repoDir} '.git'
    ${venvPy} = Join-Path ${repoDir} '.venv\Scripts\python.exe'

    if (-not (Test-Path -LiteralPath ${repoDir})) {
        [void]${issues}.Add("Repo directory missing: ${repoDir}")
        continue
    }
    if (-not (Test-Path -LiteralPath ${gitDir})) {
        [void]${issues}.Add("Incomplete clone (no .git): ${repoDir}")
        continue
    }
    if (-not (Test-Path -LiteralPath ${venvPy})) {
        [void]${issues}.Add("Per-repo venv missing: ${venvPy}")
    }

    if (${name} -like 'MAST_unit*') {
        ${svc} = Get-Service -Name 'MAST_unit' -ErrorAction SilentlyContinue
        if ($null -eq ${svc}) {
            [void]${issues}.Add("MAST_unit service not registered")
        } elseif (${svc}.Status -ne 'Running') {
            [void]${issues}.Add(("MAST_unit service registered but not running (status={0})" -f ${svc}.Status))
        }
    }
}

${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${verifyLog}) -ErrorAction SilentlyContinue

if (${issues}.Count -gt 0) {
    (${issues} -join [Environment]::NewLine) | Out-File -FilePath ${verifyLog} -Encoding UTF8
    if (Test-Path -LiteralPath ${smokeFile}) {
        Remove-Item -LiteralPath ${smokeFile} -Force -ErrorAction SilentlyContinue
    }
    Write-Host ("mast-verify FAILED: {0}" -f (${issues} -join '; '))
    exit 1
}

${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${smokeFile}) -ErrorAction SilentlyContinue
Set-Content -Path ${smokeFile} -Value 'mast_ok' -Encoding UTF8
("mast verify ok: {0} repos under {1}" -f ${repoSpecs}.Count, ${CloneRoot}) | Out-File -FilePath ${verifyLog} -Encoding UTF8
Write-Host 'mast-verify OK'
exit 0
