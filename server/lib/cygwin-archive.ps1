#requires -Version 5.1
# Extracting a Cygwin tree archive (cygwin64-clean.tgz, astrometry.tgz) with its symlinks intact.
#
# Windows' System32\tar.exe cannot be trusted with the symlinks in these archives:
#   - bsdtar 3.3.2 (Windows 10 19044 as released) fails on every symlink and exits 1;
#   - bsdtar 3.5.2 (the fleet's patch level) writes a relative link as a copy of its
#     target and an absolute one (/etc/pki/..., /etc/hosts, /etc/mtab) as an EMPTY FILE,
#     which is how every unit's Cygwin trust store and hosts lookup came to be empty.
# Native Windows links could not express an absolute Cygwin target anyway. So the links
# are left out of the extract and recreated by Cygwin's own ln afterwards.
#
# Restoring creates a link only where the path is missing or an empty regular file: an
# existing link, or a working copy left by an earlier extract, is kept. That makes the
# same step a repair for a unit extracted the old way, without clobbering anything a
# later Cygwin package upgrade put in place.
#
# Dot-sourced by provide-cygwin.ps1 and provide-astrometry.ps1, staged flat as a
# repofiles entry.

${script:MastMtreeLinkType} = 'type=link'
${script:MastMtreeLinkKeyword} = 'link='
${script:MastTarGlobChars} = '[\\*?\[\]]'
${script:MastSystemTar} = Join-Path ${env:SystemRoot} 'System32\tar.exe'
${script:MastUtf8NoBom} = New-Object System.Text.UTF8Encoding($false)

# Read by bash from a file rather than passed with -c: PowerShell 5.1 does not escape
# the double quotes inside a native argument, so a quoted script arrives cut in two.
${script:MastRestoreLinksSh} = @'
set -e
created=0; kept=0
while IFS=$'\t' read -r target link; do
  if [ -L "$link" ] || [ -d "$link" ] || [ -s "$link" ]; then
    kept=$((kept+1))
    continue
  fi
  mkdir -p "$(dirname "$link")"
  rm -f -- "$link"
  ln -s -- "$target" "$link"
  [ -L "$link" ]
  created=$((created+1))
done < "$1"
echo "created=$created kept=$kept"
'@

# mtree escapes a byte outside the safe set as a backslash and three octal digits.
function ConvertFrom-MastMtreeEscape {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]${Text})
    return [regex]::Replace(${Text}, '\\([0-7]{3})', {
            param(${m}) [string][char][Convert]::ToInt32(${m}.Groups[1].Value, 8)
        })
}

# One record per symlink entry: Path is the archive member name, Target the link text.
function Get-MastMtreeSymlinks {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]${Lines})
    foreach (${line} in ${Lines}) {
        if (-not ${line} -or ${line}.StartsWith('#') -or ${line}.StartsWith('/')) { continue }
        ${fields} = ${line}.Trim() -split '\s+'
        if (${fields} -notcontains ${script:MastMtreeLinkType}) { continue }
        ${linkField} = ${fields} | Where-Object { $_.StartsWith(${script:MastMtreeLinkKeyword}) } | Select-Object -First 1
        if (-not ${linkField}) { throw "mtree symlink entry has no link= keyword: ${line}" }
        [pscustomobject]@{
            Path   = ConvertFrom-MastMtreeEscape -Text ${fields}[0]
            Target = ConvertFrom-MastMtreeEscape -Text ${linkField}.Substring(${script:MastMtreeLinkKeyword}.Length)
        }
    }
}

# bsdtar -X reads glob patterns, so a literal member name has its metacharacters escaped.
function ConvertTo-MastTarExcludePattern {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]${Path})
    return [regex]::Replace(${Path}, ${script:MastTarGlobChars}, '\$0')
}

# Where an archive member lands in the Cygwin tree: './cygwin64-clean/bin/awk' with
# RootPrefix 'cygwin64-clean' under TreeRoot '/' is '/bin/awk'; './bin/plotann.py' under
# '/usr/local/astrometry' is '/usr/local/astrometry/bin/plotann.py'.
function ConvertTo-MastCygwinTreePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]${Path},
        [Parameter(Mandatory)][string]${TreeRoot},
        [AllowEmptyString()][string]${RootPrefix} = ''
    )
    ${rel} = ${Path} -replace '^\./', ''
    if (${RootPrefix}) {
        ${prefix} = ${RootPrefix}.TrimEnd('/') + '/'
        if (-not ${rel}.StartsWith(${prefix})) { throw "archive member '${Path}' is outside '${RootPrefix}'" }
        ${rel} = ${rel}.Substring(${prefix}.Length)
    }
    return ${TreeRoot}.TrimEnd('/') + '/' + ${rel}
}

# Tab-separated "target<TAB>path" lines for the restore script. A tab or newline in
# either field would split a record, so it is refused rather than mangled.
function ConvertTo-MastSymlinkTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]${Links},
        [Parameter(Mandatory)][string]${TreeRoot},
        [AllowEmptyString()][string]${RootPrefix} = ''
    )
    foreach (${link} in ${Links}) {
        ${treePath} = ConvertTo-MastCygwinTreePath -Path ${link}.Path -TreeRoot ${TreeRoot} -RootPrefix ${RootPrefix}
        foreach (${field} in ${link}.Target, ${treePath}) {
            if (${field} -match "[`t`r`n]") { throw "symlink field contains a tab or newline: '${field}'" }
        }
        "{0}`t{1}" -f ${link}.Target, ${treePath}
    }
}

function Get-MastArchiveSymlinks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]${ArchivePath},
        [Parameter(Mandatory)][string]${WorkDir}
    )
    ${mtreePath} = Join-Path ${WorkDir} 'archive.mtree'
    & ${script:MastSystemTar} -c -f "`"${mtreePath}`"" --format=mtree --options 'mtree:!all,type,link' "`"@${ArchivePath}`""
    if ($LASTEXITCODE -ne 0) { throw "tar could not list ${ArchivePath} (exit ${LASTEXITCODE})" }
    return @(Get-MastMtreeSymlinks -Lines (Get-Content -LiteralPath ${mtreePath}))
}

function Expand-MastArchiveWithoutSymlinks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]${ArchivePath},
        [Parameter(Mandatory)][string]${Destination},
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]${Links},
        [Parameter(Mandatory)][string]${WorkDir}
    )
    ${excludePath} = Join-Path ${WorkDir} 'symlinks.exclude'
    [IO.File]::WriteAllLines(${excludePath}, [string[]]@(${Links} | ForEach-Object { ConvertTo-MastTarExcludePattern -Path $_.Path }), ${script:MastUtf8NoBom})
    & ${script:MastSystemTar} -x -f "`"${ArchivePath}`"" -X "`"${excludePath}`"" -C "`"${Destination}`""
    if ($LASTEXITCODE -ne 0) { throw "tar failed ${LASTEXITCODE}" }
}

# Returns the restore script's "created=N kept=M" line; throws unless every link is accounted for.
function Restore-MastArchiveSymlinks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]${BashExe},
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]${Links},
        [Parameter(Mandatory)][string]${TreeRoot},
        [AllowEmptyString()][string]${RootPrefix} = '',
        [Parameter(Mandatory)][string]${WorkDir}
    )
    ${tablePath}  = Join-Path ${WorkDir} 'symlinks.tsv'
    ${scriptPath} = Join-Path ${WorkDir} 'restore-symlinks.sh'
    ${table} = [string[]]@(ConvertTo-MastSymlinkTable -Links ${Links} -TreeRoot ${TreeRoot} -RootPrefix ${RootPrefix})
    [IO.File]::WriteAllText(${tablePath}, ((${table} -join "`n") + "`n"), ${script:MastUtf8NoBom})
    [IO.File]::WriteAllText(${scriptPath}, (${script:MastRestoreLinksSh} -replace "`r", ''), ${script:MastUtf8NoBom})
    ${cygpath} = Join-Path (Split-Path -Parent ${BashExe}) 'cygpath.exe'
    ${scriptPosix} = & ${cygpath} -u ${scriptPath}
    ${tablePosix}  = & ${cygpath} -u ${tablePath}
    ${out} = @(& ${BashExe} -l ${scriptPosix} ${tablePosix})
    if ($LASTEXITCODE -ne 0) { throw "restoring archive symlinks failed (exit ${LASTEXITCODE}): $(${out} -join ' ')" }
    ${summary} = [string](${out} | Select-Object -Last 1)
    if (${summary} -notmatch '^created=(\d+) kept=(\d+)$' -or ([int]${Matches}[1] + [int]${Matches}[2]) -ne ${Links}.Count) {
        throw "restoring archive symlinks: expected $(${Links}.Count) entries, got '${summary}'"
    }
    return ${summary}
}
