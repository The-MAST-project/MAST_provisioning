<#
.SYNOPSIS
    Lint the repo's PowerShell. The entry point for CI and for a workstation.

.DESCRIPTION
    One command so CI and a developer see the same verdict, the same way
    `ruff check .` serves both for Python.

    Scans TRACKED files via `git ls-files`, not -Recurse: staging\ holds copies of
    every provider script and would double-count the whole tree (the same trap the
    untracked common/ clone sets for filesystem walks).

    Rules and exclusions come from PSScriptAnalyzerSettings.psd1. Accepted findings
    are suppressed at the site with SuppressMessageAttribute where there is a
    function or param block to attach one to; where there is not, they live in
    tools/pssa-baseline.txt, which this script filters out. A baseline entry is
    "<rule>|<repo-relative path>|<line>" and every one of them needs a reason on
    the line above it.

    The baseline exists because PSScriptAnalyzer has no per-line suppression
    comment and its settings cannot exclude a rule per path -- so without it, the
    only way to accept one finding is to stop enforcing its rule everywhere.

.PARAMETER UpdateBaseline
    Rewrite tools/pssa-baseline.txt from what is currently reported. Review the
    diff: this is how an accepted finding is recorded, and also how a real one
    would be hidden.
#>
[CmdletBinding()]
param(
    [switch]${UpdateBaseline},
    [switch]${NoGallery}
)

${ErrorActionPreference} = 'Stop'
${repoRoot} = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath ${repoRoot}

${modulePath} = & (Join-Path $PSScriptRoot 'install-psscriptanalyzer.ps1') -NoGallery:${NoGallery} |
    Select-Object -Last 1
Import-Module ${modulePath} -Force
Write-Host ("PSScriptAnalyzer {0} on PowerShell {1}" -f (Get-Module PSScriptAnalyzer).Version, ${PSVersionTable}.PSVersion)

${settings} = Join-Path ${repoRoot} 'PSScriptAnalyzerSettings.psd1'
${baselineFile} = Join-Path $PSScriptRoot 'pssa-baseline.txt'
${files} = @(& git ls-files '*.ps1' '*.psm1')
Write-Host ("scanning {0} tracked PowerShell files" -f ${files}.Count)

${found} = @()
foreach (${f} in ${files}) {
    ${found} += Invoke-ScriptAnalyzer -Path ${f} -Settings ${settings} -ErrorAction SilentlyContinue
}

function Get-Key {
    param($Finding)
    ${rel} = ${Finding}.ScriptPath -replace [regex]::Escape((Get-Location).Path + '\'), ''
    return ("{0}|{1}|{2}" -f ${Finding}.RuleName, (${rel} -replace '\\', '/'), ${Finding}.Line)
}

if (${UpdateBaseline}) {
    ${lines} = @('# PSScriptAnalyzer findings accepted WITHOUT a SuppressMessageAttribute,',
                 '# because they have no function or param block to attach one to.',
                 '# Regenerate with tools/invoke-psscriptanalyzer.ps1 -UpdateBaseline, and',
                 '# never without reading the diff: this file can hide a real finding as',
                 '# easily as it records an accepted one. Format: <rule>|<path>|<line>.',
                 '')
    ${lines} += (${found} | ForEach-Object { Get-Key -Finding $_ } | Sort-Object -Unique)
    Set-Content -LiteralPath ${baselineFile} -Value ${lines} -Encoding UTF8
    Write-Host ("baseline rewritten with {0} entries" -f (${found}.Count))
    exit 0
}

${baseline} = @()
if (Test-Path -LiteralPath ${baselineFile}) {
    ${baseline} = @(Get-Content -LiteralPath ${baselineFile} |
        Where-Object { $_ -match '\S' -and -not $_.StartsWith('#') })
}

${remaining} = @(${found} | Where-Object { ${baseline} -notcontains (Get-Key -Finding $_) })
${suppressed} = ${found}.Count - ${remaining}.Count
Write-Host ("{0} finding(s); {1} accepted via the baseline" -f ${found}.Count, ${suppressed})

if (${remaining}.Count -gt 0) {
    Write-Host ''
    foreach (${r} in (${remaining} | Sort-Object RuleName, ScriptName, Line)) {
        ${rel} = ${r}.ScriptPath -replace [regex]::Escape((Get-Location).Path + '\'), ''
        Write-Host ("[{0}] {1}:{2}  {3}" -f ${r}.Severity, (${rel} -replace '\\', '/'), ${r}.Line, ${r}.Message)
    }
    Write-Host ''
    Write-Host ("FAIL: {0} unaccepted finding(s)." -f ${remaining}.Count)
    exit 1
}

Write-Host 'PowerShell lint clean.'
