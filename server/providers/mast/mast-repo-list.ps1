# Dot-source from provide-mast.ps1 and verify-mast.ps1.
# Repo definitions live in mast-repos.txt (single source of truth).
# Each returned object has:
#   .RepoSpec  - host/org/repo  (no https://, no .git)
#   .Ref       - branch, tag, or commit hash; empty string means default branch
function Read-MastRepoSpecFile {
    param(
        [Parameter(Mandatory)][string]${Path}
    )
    if (-not (Test-Path -LiteralPath ${Path})) {
        throw "Mast repo list file not found: ${Path}"
    }
    ${entries} = New-Object 'System.Collections.Generic.List[object]'
    Get-Content -LiteralPath ${Path} -ErrorAction Stop | ForEach-Object {
        ${line} = $_.Trim()
        if (-not ${line}) { return }
        if (${line}.StartsWith('#')) { return }
        ${parts} = ${line} -split '\s+', 2
        ${entries}.Add([PSCustomObject]@{
            RepoSpec = ${parts}[0]
            Ref      = $(if (${parts}.Count -gt 1) { ${parts}[1] } else { '' })
        })
    }
    if (${entries}.Count -eq 0) {
        throw "Mast repo list file has no repo lines: ${Path}"
    }
    return ${entries}.ToArray()
}
