#requires -Version 5.1
# The one definition of "Win32 long paths are enabled", shared by the provide and
# verify scripts so the key they write and the key they check cannot differ.
#
# Windows reads the value when a process starts, so a process that was already
# running when it changed keeps the 260-character MAX_PATH limit until restarted.

${script:MastLongPathsKey}   = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
${script:MastLongPathsName}  = 'LongPathsEnabled'
${script:MastLongPathsValue} = 1

function Get-MastLongPathsEnabled {
    # The live value, or $null when the value does not exist (Windows then treats
    # long paths as disabled).
    ${item} = Get-ItemProperty -LiteralPath ${script:MastLongPathsKey} -Name ${script:MastLongPathsName} -ErrorAction SilentlyContinue
    if ($null -eq ${item}) { return $null }
    return [int]${item}.${script:MastLongPathsName}
}

function Test-MastLongPathsEnabled {
    return ((Get-MastLongPathsEnabled) -eq ${script:MastLongPathsValue})
}

function Set-MastLongPathsEnabled {
    Set-ItemProperty -LiteralPath ${script:MastLongPathsKey} -Name ${script:MastLongPathsName} -Value ${script:MastLongPathsValue} -Type DWord
}
