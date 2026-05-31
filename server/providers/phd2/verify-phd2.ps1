#requires -Version 5.1
# Must match provide-phd2.ps1 (installer default paths).
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts predate it and probe optional properties
${verifyLog} = Get-MastVerifyLog -Module 'phd2'
${candidates} = @(
    'C:\Program Files (x86)\PHDGuiding2\phd2.exe',
    'C:\Program Files\PHD2\phd2.exe'
)
${found} = $null
foreach (${c} in ${candidates}) {
    if (Test-Path -LiteralPath ${c}) {
        ${found} = ${c}
        break
    }
}
if (-not ${found}) {
    ('phd2.exe not found (checked: {0})' -f (${candidates} -join '; ')) | Out-File -FilePath ${verifyLog} -Encoding UTF8
    exit 1
}
("PHD2 OK: {0}" -f ${found}) | Out-File -FilePath ${verifyLog} -Encoding UTF8
Write-MastSmokeOk -Module 'phd2' | Out-Null
exit 0
