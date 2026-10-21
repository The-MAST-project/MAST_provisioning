#requires -Version 5.1
# Verify LongPathsEnabled live, not from the smoke marker: a value changed out of
# band after a clean run produces no payload-hash drift, so this read is the only
# thing that would notice.
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${libPath} = Join-Path ${PSScriptRoot} 'mast-long-paths-lib.ps1'
if (-not (Test-Path ${libPath})) { throw 'mast-long-paths-lib.ps1 not found next to verify-long-paths.ps1' }
. ${libPath}

${verifyLog} = Get-MastVerifyLog -Module 'long-paths'

if (-not (Test-MastLongPathsEnabled)) {
    Write-MastLog -LogFile ${verifyLog} -Message ("FAIL: {0} = {1}, expected {2}." -f ${script:MastLongPathsName}, (Get-MastLongPathsEnabled), ${script:MastLongPathsValue})
    exit 1
}

Write-MastLog -LogFile ${verifyLog} -Message ("OK: {0} = {1}." -f ${script:MastLongPathsName}, ${script:MastLongPathsValue})
exit 0
