#requires -Version 5.1
# Enable Win32 long paths (LongPathsEnabled = 1) machine-wide. See #248.
#
# Products moved to the shared area by UNC path exceed MAX_PATH (263 characters
# measured on mast00), and without this setting the move fails and is retried
# forever while the product sits on the RAM disk.
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${libPath} = Join-Path ${PSScriptRoot} 'mast-long-paths-lib.ps1'
if (-not (Test-Path ${libPath})) { throw 'mast-long-paths-lib.ps1 not found next to provide-long-paths.ps1' }
. ${libPath}

${module} = 'long-paths'
${verifyLog} = Get-MastVerifyLog -Module ${module}

${before} = Get-MastLongPathsEnabled
if (Test-MastLongPathsEnabled) {
    Write-MastLog -LogFile ${verifyLog} -Message ("{0} is already {1}; nothing to do." -f ${script:MastLongPathsName}, ${before})
}
else {
    Set-MastLongPathsEnabled
    Write-MastLog -LogFile ${verifyLog} -Message ("{0} set: {1} -> {2}. Processes started before now keep MAX_PATH until restarted." -f ${script:MastLongPathsName}, $(if ($null -eq ${before}) { 'absent' } else { ${before} }), ${script:MastLongPathsValue})
}

if (-not (Test-MastLongPathsEnabled)) {
    Write-MastLog -LogFile ${verifyLog} -Message ("FAIL: {0} reads {1} after the write." -f ${script:MastLongPathsName}, (Get-MastLongPathsEnabled))
    exit 1
}

${null} = Write-MastSmokeOk -Module ${module}
exit 0
