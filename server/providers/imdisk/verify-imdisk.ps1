#requires -Version 5.1
# Verify ImDisk is installed and D:\mast-indexes holds the declared index set (#254),
# read live from the installed manifest: a D: that changed after a clean run produces no
# payload-hash drift, so this read is what notices.
[CmdletBinding()]
param(
    [string]${InstalledManifest} = 'C:\MAST\state\mast-indexes.json',
    [string]${IndexDir} = 'D:\mast-indexes'
)

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${libPath} = Join-Path ${PSScriptRoot} 'mast-index-manifest-lib.ps1'
if (-not (Test-Path ${libPath})) { throw 'mast-index-manifest-lib.ps1 not found next to verify-imdisk.ps1' }
. ${libPath}

${module} = 'imdisk'
${verifyLog} = Get-MastVerifyLog -Module ${module}

if (-not (Test-Path 'C:\Windows\System32\imdisk.exe')) {
    Write-MastLog -LogFile ${verifyLog} -Message 'FAIL: ImDisk executable not found.'
    exit 1
}
if (-not (Test-Path -LiteralPath ${InstalledManifest})) {
    Write-MastLog -LogFile ${verifyLog} -Message ("FAIL: no declared index set at {0}." -f ${InstalledManifest})
    exit 1
}
${expected} = @(Read-MastIndexManifest -Path ${InstalledManifest})
${diff} = @(Get-MastIndexSetMismatches -Expected ${expected} -Actual @(Get-MastIndexFolderEntries -Dir ${IndexDir}))
if (${diff}.Count -gt 0) {
    Write-MastLog -LogFile ${verifyLog} -Message ("FAIL: {0} differs from the declared index set: {1}" -f ${IndexDir}, (${diff} -join '; '))
    exit 1
}

Write-MastLog -LogFile ${verifyLog} -Message ("OK: ImDisk installed; {0} holds the declared index set ({1} files)." -f ${IndexDir}, ${expected}.Count)
${null} = Write-MastSmokeOk -Module ${module}
exit 0
