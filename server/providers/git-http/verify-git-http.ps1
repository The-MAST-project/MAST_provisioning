#requires -Version 5.1
# Verify git's --system HTTP settings live, not from the smoke marker: a value
# changed out of band after a clean run produces no payload-hash drift, so this
# read is the only thing that would notice.
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${libPath} = Join-Path ${PSScriptRoot} 'mast-git-http-lib.ps1'
if (-not (Test-Path ${libPath})) { throw 'mast-git-http-lib.ps1 not found next to verify-git-http.ps1' }
. ${libPath}

${verifyLog} = Get-MastVerifyLog -Module 'git-http'

${bad} = Get-MastGitHttpMismatches -GitExe (Get-MastGitExe)
if (${bad}.Count -gt 0) {
    foreach (${line} in ${bad}) { Write-MastLog -LogFile ${verifyLog} -Message ("FAIL: {0}" -f ${line}) }
    exit 1
}

Write-MastLog -LogFile ${verifyLog} -Message 'OK: git --system HTTP settings match.'
exit 0
