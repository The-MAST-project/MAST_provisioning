#requires -Version 5.1
# The astrometry index set as a manifest: one file name and size per index file.
#
# server/data/assets.json is the canonical declaration (its 'mast-indexes' rows).
# build-mast.ps1 turns those rows into mast-indexes.json with
# ConvertTo-MastIndexManifestJson and stages it beside this file; the imdisk
# provider installs it on the unit as C:\MAST\state\mast-indexes.json, which the
# supervisor and the unit's own checks read. Dot-sourced by build-mast.ps1,
# provide-imdisk.ps1 and verify-imdisk.ps1, so the build, the provider and verify
# compare a folder the same way.

function ConvertTo-MastIndexManifestJson {
    # One canonical spelling, sorted by name, so the same set always yields the same
    # bytes and the same digest. Hand-built because ConvertTo-Json's layout differs
    # between PowerShell versions.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries)
    $rows = @($Entries | Sort-Object Name | ForEach-Object {
            '    {{"name": "{0}", "size": {1}}}' -f $_.Name, [long]$_.Size
        })
    return ("{{`n  ""source"": ""mast-indexes"",`n  ""files"": [`n{0}`n  ]`n}}`n" -f ($rows -join ",`n"))
}

function Read-MastIndexManifest {
    param([Parameter(Mandatory)][string]$Path)
    $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    return @($doc.files | ForEach-Object { [pscustomobject]@{ Name = [string]$_.name; Size = [long]$_.size } })
}

function Get-MastIndexFolderEntries {
    # The files directly in $Dir; none when it does not exist.
    param([Parameter(Mandatory)][string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Dir -File | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Size = [long]$_.Length } })
}

function Get-MastIndexSetMismatches {
    # How $Actual differs from $Expected: a missing, extra or wrong-sized file each
    # give one line. Empty when they match. Names compare case-insensitively, as
    # Windows does.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Expected,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actual
    )
    $want = @{}
    foreach ($e in $Expected) { $want[$e.Name] = [long]$e.Size }
    $have = @{}
    foreach ($a in $Actual) { $have[$a.Name] = [long]$a.Size }
    $out = @()
    foreach ($name in ($want.Keys | Sort-Object)) {
        if (-not $have.ContainsKey($name)) {
            $out += "missing $name"
        } elseif ($have[$name] -ne $want[$name]) {
            $out += ("wrong size {0}: {1} bytes, expected {2}" -f $name, $have[$name], $want[$name])
        }
    }
    foreach ($name in ($have.Keys | Sort-Object)) {
        if (-not $want.ContainsKey($name)) { $out += "extra $name" }
    }
    return $out
}

function Get-MastIndexManifestDigest {
    # SHA-256 of the manifest text as Write-MastIndexManifest writes it, in the form
    # Get-FileHash reports, so the provider can check the staged file against the
    # digest the build put on its command line.
    param([Parameter(Mandatory)][string]$Json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (-join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Json)) | ForEach-Object { $_.ToString('X2') }))
    } finally {
        $sha.Dispose()
    }
}

function Write-MastIndexManifest {
    # UTF-8 without a BOM: the supervisor and the unit read this file from Python.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Json
    )
    [System.IO.File]::WriteAllText($Path, $Json, (New-Object System.Text.UTF8Encoding $false))
}
