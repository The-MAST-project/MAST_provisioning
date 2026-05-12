# Dot-source from provide-mast.ps1 and verify-mast.ps1.
# Repo definitions live in mast-repos.txt (single source of truth).
function Read-MastRepoSpecFile {
    param(
        [Parameter(Mandatory)][string]${Path}
    )
    if (-not (Test-Path -LiteralPath ${Path})) {
        throw "Mast repo list file not found: ${Path}"
    }
    ${lines} = New-Object 'System.Collections.Generic.List[string]'
    Get-Content -LiteralPath ${Path} -ErrorAction Stop | ForEach-Object {
        ${line} = $_.Trim()
        if (-not ${line}) { return }
        if (${line}.StartsWith('#')) { return }
        ${lines}.Add(${line})
    }
    if (${lines}.Count -eq 0) {
        throw "Mast repo list file has no repo lines: ${Path}"
    }
    return ${lines}.ToArray()
}
