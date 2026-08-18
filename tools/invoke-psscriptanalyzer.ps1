<#
.SYNOPSIS
    Lint the repo's PowerShell. The entry point for CI and for a workstation.

.DESCRIPTION
    One command so CI and a developer see the same verdict, the same way
    `ruff check .` serves both for Python.

    Scans TRACKED files via `git ls-files`, not -Recurse: staging\ holds copies of
    every provider script and would double-count the whole tree (the same trap the
    untracked common/ clone sets for filesystem walks).

    Rules and exclusions come from PSScriptAnalyzerSettings.psd1.

    PSScriptAnalyzer has no per-line suppression comment, so this script reads one
    of its own. An accepted finding is annotated AT THE LINE:

        # pssa-ignore: <RuleName> -- why this one is accepted
        & git -C $dest remote get-url origin | ForEach-Object { $actual = $_ }

    ...with a real rule name in place of <RuleName>. The example is written with a
    placeholder on purpose: this script scans itself, so a literal one here would be
    read as an annotation, match no finding, and be reported stale.

    The annotation may sit on the flagged line as a trailing comment or on the line
    immediately above it. It must name the rule -- there is no blanket form -- and
    it must carry a reason after '--', which this script enforces. Several rules may
    be listed comma-separated.

    Annotations travel with the code, which a line-numbered baseline cannot: editing
    a file above an accepted finding used to invalidate its entry silently.

    A STALE annotation is an error too. If an annotated line stops producing the
    finding it dismisses, the annotation is reported rather than left to rot -- the
    same reason ruff reports an unused noqa.

    Where a finding has a function or param block to attach to, prefer PSSA's own
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute] with a Justification: it is
    native, and the analyzer understands it without this script's help.
#>
[CmdletBinding()]
param(
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
${files} = @(& git ls-files '*.ps1' '*.psm1')
Write-Host ("scanning {0} tracked PowerShell files" -f ${files}.Count)

${found} = @()
foreach (${f} in ${files}) {
    ${found} += Invoke-ScriptAnalyzer -Path ${f} -Settings ${settings} -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Annotations: '# pssa-ignore: <Rule>[,<Rule>] -- <reason>'
# ---------------------------------------------------------------------------
${annotationPattern} = '#\s*pssa-ignore\s*:\s*([A-Za-z0-9, ]+?)\s*(--\s*(.*))?$'

function Get-Annotation {
    # The annotation on a given 1-based line, or $null. Returns the rules it names
    # and the reason, so a missing reason can be reported rather than honoured.
    param([string[]]${Lines}, [int]${Number})
    if (${Number} -lt 1 -or ${Number} -gt ${Lines}.Count) { return $null }
    ${text} = ${Lines}[${Number} - 1]
    ${m} = [regex]::Match(${text}, ${annotationPattern})
    if (-not ${m}.Success) { return $null }
    ${rules} = @(${m}.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    ${reason} = ''
    if (${m}.Groups[3].Success) { ${reason} = ${m}.Groups[3].Value.Trim() }
    return [pscustomobject]@{ Rules = ${rules}; Reason = ${reason}; Line = ${Number}; Text = ${text}.Trim() }
}

${lineCache} = @{}
function Get-FileLines {
    param([string]${Path})
    if (-not ${lineCache}.ContainsKey(${Path})) {
        ${lineCache}[${Path}] = @(Get-Content -LiteralPath ${Path} -Encoding UTF8)
    }
    return ${lineCache}[${Path}]
}

${remaining} = @()
${dismissed} = 0
${malformed} = @()
${honoured} = @{}   # "<path>|<annotation line>|<rule>" -> $true, to find stale ones

foreach (${r} in ${found}) {
    ${lines} = Get-FileLines -Path ${r}.ScriptPath
    # Trailing comment on the flagged line first, then the line above it.
    ${ann} = Get-Annotation -Lines ${lines} -Number ${r}.Line
    if ($null -eq ${ann} -or -not (${ann}.Rules -contains ${r}.RuleName)) {
        ${ann} = Get-Annotation -Lines ${lines} -Number (${r}.Line - 1)
    }
    if ($null -ne ${ann} -and (${ann}.Rules -contains ${r}.RuleName)) {
        if (-not ${ann}.Reason) {
            ${malformed} += [pscustomobject]@{ Path = ${r}.ScriptPath; Line = ${ann}.Line; Text = ${ann}.Text }
        } else {
            ${dismissed}++
            ${honoured}[("{0}|{1}|{2}" -f ${r}.ScriptPath, ${ann}.Line, ${r}.RuleName)] = $true
        }
        continue
    }
    ${remaining} += ${r}
}

# Stale annotations: named a rule that the line no longer produces.
${stale} = @()
foreach (${f} in ${files}) {
    ${full} = (Resolve-Path -LiteralPath ${f}).Path
    ${lines} = Get-FileLines -Path ${full}
    for (${i} = 1; ${i} -le ${lines}.Count; ${i}++) {
        ${ann} = Get-Annotation -Lines ${lines} -Number ${i}
        if ($null -eq ${ann}) { continue }
        foreach (${rule} in ${ann}.Rules) {
            if (-not ${honoured}.ContainsKey(("{0}|{1}|{2}" -f ${full}, ${i}, ${rule}))) {
                ${stale} += [pscustomobject]@{ Path = ${f}; Line = ${i}; Rule = ${rule} }
            }
        }
    }
}

Write-Host ("{0} finding(s); {1} dismissed by annotation" -f ${found}.Count, ${dismissed})

${failed} = $false

if (${malformed}.Count -gt 0) {
    Write-Host ''
    foreach (${m2} in ${malformed}) {
        ${rel} = ${m2}.Path -replace [regex]::Escape((Get-Location).Path + '\'), ''
        Write-Host ("[annotation] {0}:{1}  pssa-ignore without a reason: {2}" -f (${rel} -replace '\\', '/'), ${m2}.Line, ${m2}.Text)
    }
    Write-Host 'An annotation must say why: "# pssa-ignore: <Rule> -- <reason>".'
    ${failed} = $true
}

if (${stale}.Count -gt 0) {
    Write-Host ''
    foreach (${st} in ${stale}) {
        Write-Host ("[annotation] {0}:{1}  stale pssa-ignore for {2}: that line no longer reports it" -f ${st}.Path, ${st}.Line, ${st}.Rule)
    }
    Write-Host 'Remove the annotation, or move it to the line that needs it.'
    ${failed} = $true
}

if (${remaining}.Count -gt 0) {
    Write-Host ''
    foreach (${r} in (${remaining} | Sort-Object RuleName, ScriptName, Line)) {
        ${rel} = ${r}.ScriptPath -replace [regex]::Escape((Get-Location).Path + '\'), ''
        Write-Host ("[{0}] {1}:{2}  {3}" -f ${r}.Severity, (${rel} -replace '\\', '/'), ${r}.Line, ${r}.Message)
    }
    Write-Host ''
    Write-Host ("FAIL: {0} unaccepted finding(s)." -f ${remaining}.Count)
    ${failed} = $true
}

if (${failed}) { exit 1 }
Write-Host 'PowerShell lint clean.'
