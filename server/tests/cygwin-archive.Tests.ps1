# Pester unit tests for server/lib/cygwin-archive.ps1: reading a Cygwin tree archive's
# symlinks from bsdtar's mtree listing, so the cygwin and astrometry providers can leave
# them out of the extract and recreate them with Cygwin's ln. The extract and the bash
# restore act on a machine with Cygwin and are exercised by a provisioning run, not here.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\cygwin-archive.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\lib\cygwin-archive.ps1')

# Lines as bsdtar writes them for `--options 'mtree:!all,type,link'`.
$mtree = @(
    '#mtree',
    './cygwin64-clean type=dir',
    './cygwin64-clean/bin/awk type=link link=gawk.exe',
    './cygwin64-clean/bin/bash.exe type=file',
    './cygwin64-clean/usr/share/doc/a\040b type=link link=/usr/share/x\040y',
    './cygwin64-clean/bin/[ type=link link=test.exe'
)

Describe 'Get-MastMtreeSymlinks' {
    $links = @(Get-MastMtreeSymlinks -Lines $mtree)

    It 'returns only the symlink entries' {
        $links.Count | Should Be 3
    }
    It 'reads the member name and the link target' {
        $links[0].Path | Should Be './cygwin64-clean/bin/awk'
        $links[0].Target | Should Be 'gawk.exe'
    }
    It 'decodes mtree octal escapes in both fields' {
        $links[1].Path | Should Be './cygwin64-clean/usr/share/doc/a b'
        $links[1].Target | Should Be '/usr/share/x y'
    }
    It 'returns nothing for a listing with no symlinks' {
        @(Get-MastMtreeSymlinks -Lines @('#mtree', './a type=file')).Count | Should Be 0
    }
    It 'refuses a symlink entry without a target' {
        { Get-MastMtreeSymlinks -Lines @('./a type=link') } | Should Throw
    }
}

Describe 'ConvertTo-MastTarExcludePattern' {
    It 'leaves a plain name as it is' {
        ConvertTo-MastTarExcludePattern -Path './cygwin64-clean/bin/awk' | Should Be './cygwin64-clean/bin/awk'
    }
    It 'escapes glob metacharacters so the name matches only itself' {
        ConvertTo-MastTarExcludePattern -Path './bin/[' | Should Be './bin/\['
        ConvertTo-MastTarExcludePattern -Path './a*b?c' | Should Be './a\*b\?c'
    }
}

Describe 'ConvertTo-MastCygwinTreePath' {
    It 'strips the archive top folder' {
        ConvertTo-MastCygwinTreePath -Path './cygwin64-clean/bin/awk' -TreeRoot '/' -RootPrefix 'cygwin64-clean' | Should Be '/bin/awk'
    }
    It 'places a tree stored without a top folder under its install root' {
        ConvertTo-MastCygwinTreePath -Path './bin/plotann.py' -TreeRoot '/usr/local/astrometry' | Should Be '/usr/local/astrometry/bin/plotann.py'
    }
    It 'tolerates a trailing slash on the install root' {
        ConvertTo-MastCygwinTreePath -Path './bin/awk' -TreeRoot '/usr/local/x/' | Should Be '/usr/local/x/bin/awk'
    }
    It 'refuses a member outside the top folder' {
        { ConvertTo-MastCygwinTreePath -Path './other/bin/awk' -TreeRoot '/' -RootPrefix 'cygwin64-clean' } | Should Throw
    }
}

Describe 'ConvertTo-MastSymlinkTable' {
    It 'writes target and tree path separated by a tab' {
        $links = @([pscustomobject]@{ Path = './cygwin64-clean/bin/awk'; Target = 'gawk.exe' })
        ConvertTo-MastSymlinkTable -Links $links -TreeRoot '/' -RootPrefix 'cygwin64-clean' | Should Be "gawk.exe`t/bin/awk"
    }
    It 'refuses a field that would split the record' {
        $links = @([pscustomobject]@{ Path = './cygwin64-clean/bin/x'; Target = "a`tb" })
        { ConvertTo-MastSymlinkTable -Links $links -TreeRoot '/' -RootPrefix 'cygwin64-clean' } | Should Throw
    }
}

Describe 'Restore-MastArchiveSymlinks' {
    It 'has nothing to do for an archive without symlinks, and does not start bash' {
        Restore-MastArchiveSymlinks -BashExe 'C:\no\such\bash.exe' -Links @() -TreeRoot '/' -WorkDir $env:TEMP | Should Be 'created=0 kept=0 skipped=0'
    }
}
