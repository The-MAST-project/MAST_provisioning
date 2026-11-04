#requires -Version 5.1
# Make git speak HTTP/1.1, and abort a stalled transfer, machine-wide (#220).
# Written to the --system config, so every account on the machine gets it: the
# provisioning run, the interactive operator and anything a service starts.
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${libPath} = Join-Path ${PSScriptRoot} 'mast-git-http-lib.ps1'
if (-not (Test-Path ${libPath})) { throw 'mast-git-http-lib.ps1 not found next to provide-git-http.ps1' }
. ${libPath}

${module} = 'git-http'
${verifyLog} = Get-MastVerifyLog -Module ${module}
${gitExe} = Get-MastGitExe

${before} = Get-MastGitHttpMismatches -GitExe ${gitExe}
if (${before}.Count -eq 0) {
    Write-MastLog -LogFile ${verifyLog} -Message 'git --system HTTP settings already match; nothing to do.'
}
else {
    foreach (${line} in ${before}) { Write-MastLog -LogFile ${verifyLog} -Message ("setting: {0}" -f ${line}) }
    Set-MastGitHttpConfig -GitExe ${gitExe}
}

${after} = Get-MastGitHttpMismatches -GitExe ${gitExe}
if (${after}.Count -gt 0) {
    foreach (${line} in ${after}) { Write-MastLog -LogFile ${verifyLog} -Message ("FAIL after the write: {0}" -f ${line}) }
    exit 1
}

${null} = Write-MastSmokeOk -Module ${module}
exit 0
