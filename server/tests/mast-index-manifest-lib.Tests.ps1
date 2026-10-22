# Unit tests for the astrometry index-set manifest (#254):
#   - server/providers/imdisk/mast-index-manifest-lib.ps1, shared by the build, the
#     imdisk provider and its verify;
#   - Get-MastDeclaredIndexSet in build/build-staging-lib.ps1, which reads the set
#     server/data/assets.json declares.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\mast-index-manifest-lib.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\providers\imdisk\mast-index-manifest-lib.ps1')
. (Join-Path $here '..\..\build\build-staging-lib.ps1')

$root = Join-Path $env:TEMP ("mast-index-manifest-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null

function New-Entry([string]$Name, [long]$Size) { [pscustomobject]@{ Name = $Name; Size = $Size } }

function New-IndexFolder([string]$Name, [object[]]$Files) {
    $dir = Join-Path $root $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($f in $Files) {
        [System.IO.File]::WriteAllBytes((Join-Path $dir $f.Name), (New-Object byte[] $f.Size))
    }
    return $dir
}

$declared = @((New-Entry 'index-5202-00.fits' 3), (New-Entry 'index-5202-01.fits' 5))

Describe 'Get-MastIndexSetMismatches' {
    It 'is empty when the folder holds exactly the declared set' {
        @(Get-MastIndexSetMismatches -Expected $declared -Actual $declared).Count | Should Be 0
    }
    It 'names a missing file' {
        $r = @(Get-MastIndexSetMismatches -Expected $declared -Actual @($declared[0]))
        $r | Should Be @('missing index-5202-01.fits')
    }
    It 'names an extra file' {
        $r = @(Get-MastIndexSetMismatches -Expected $declared -Actual ($declared + @(New-Entry 'index-5206-00.fits' 1)))
        $r | Should Be @('extra index-5206-00.fits')
    }
    It 'names a wrong-sized file with both sizes' {
        $r = @(Get-MastIndexSetMismatches -Expected $declared -Actual @($declared[0], (New-Entry 'index-5202-01.fits' 4)))
        $r | Should Be @('wrong size index-5202-01.fits: 4 bytes, expected 5')
    }
    It 'compares names case-insensitively, as Windows does' {
        $r = @(Get-MastIndexSetMismatches -Expected $declared -Actual @((New-Entry 'INDEX-5202-00.FITS' 3), $declared[1]))
        $r.Count | Should Be 0
    }
    It 'reports every file missing for an empty folder' {
        @(Get-MastIndexSetMismatches -Expected $declared -Actual @()).Count | Should Be 2
    }
}

Describe 'Get-MastIndexFolderEntries' {
    It 'reads names and sizes, and nothing for a missing folder' {
        $dir = New-IndexFolder 'folder' $declared
        $r = @(Get-MastIndexFolderEntries -Dir $dir | Sort-Object Name)
        ($r | ForEach-Object { "$($_.Name)=$($_.Size)" }) -join ',' | Should Be 'index-5202-00.fits=3,index-5202-01.fits=5'
        @(Get-MastIndexFolderEntries -Dir (Join-Path $root 'absent')).Count | Should Be 0
    }
}

Describe 'the manifest file' {
    It 'round-trips through ConvertTo-MastIndexManifestJson and Read-MastIndexManifest' {
        $path = Join-Path $root 'mast-indexes.json'
        [System.IO.File]::WriteAllText($path, (ConvertTo-MastIndexManifestJson -Entries $declared), (New-Object System.Text.UTF8Encoding $false))
        $r = @(Read-MastIndexManifest -Path $path)
        @(Get-MastIndexSetMismatches -Expected $declared -Actual $r).Count | Should Be 0
    }
    It 'is the same text whatever order the entries arrive in' {
        $a = ConvertTo-MastIndexManifestJson -Entries $declared
        $b = ConvertTo-MastIndexManifestJson -Entries @($declared[1], $declared[0])
        $a | Should BeExactly $b
    }
    It 'is written as JSON a non-PowerShell reader takes as is: no BOM' {
        $path = Join-Path $root 'nobom.json'
        Write-MastIndexManifest -Path $path -Json (ConvertTo-MastIndexManifestJson -Entries $declared)
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0] | Should Be ([byte][char]'{')
    }
    It 'has a digest that matches Get-FileHash of the written file' {
        $path = Join-Path $root 'digest.json'
        $json = ConvertTo-MastIndexManifestJson -Entries $declared
        Write-MastIndexManifest -Path $path -Json $json
        Get-MastIndexManifestDigest -Json $json | Should Be (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
    }
}

Describe 'Get-MastDeclaredIndexSet' {
    It 'takes the mast-indexes rows of assets.json, by file name and size' {
        $assets = Join-Path $root 'assets.json'
        Set-Content -LiteralPath $assets -Encoding Ascii -Value @'
{"files": [
  {"path": "server/providers/imdisk/assets/mast-indexes/index-5202-00.fits", "size": 3, "source": "mast-indexes"},
  {"path": "server/providers/cygwin/assets/other.tgz", "size": 9, "source": "cygwin"}
]}
'@
        $r = @(Get-MastDeclaredIndexSet -AssetsJson $assets)
        ($r | ForEach-Object { "$($_.Name)=$($_.Size)" }) -join ',' | Should Be 'index-5202-00.fits=3'
    }
    It 'fails when assets.json declares no index files' {
        $assets = Join-Path $root 'empty.json'
        Set-Content -LiteralPath $assets -Encoding Ascii -Value '{"files": []}'
        { Get-MastDeclaredIndexSet -AssetsJson $assets } | Should Throw
    }
    It 'reads the repository''s own declaration: 96 files, series 5202 and 5203' {
        $r = @(Get-MastDeclaredIndexSet -AssetsJson (Join-Path $here '..\data\assets.json'))
        $r.Count | Should Be 96
        (@($r | ForEach-Object { $_.Name.Substring(6, 4) } | Sort-Object -Unique) -join ',') | Should Be '5202,5203'
    }
}

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
