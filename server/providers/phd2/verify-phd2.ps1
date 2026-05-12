#requires -Version 5.1
# Must match provide-phd2.ps1 (installer default paths).
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${logRoot} = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'logs'
${verifyLog} = Join-Path ${logRoot} 'verify\phd2-verify.log'
${smokeFile} = Join-Path ${logRoot} 'smoke\phd2-smoke.txt'
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
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${verifyLog}) -ErrorAction SilentlyContinue
if (-not ${found}) {
    ('phd2.exe not found (checked: {0})' -f (${candidates} -join '; ')) | Out-File -FilePath ${verifyLog} -Encoding UTF8
    exit 1
}
("PHD2 OK: {0}" -f ${found}) | Out-File -FilePath ${verifyLog} -Encoding UTF8
Set-Content -Path ${smokeFile} -Value 'phd2_ok' -Encoding UTF8
exit 0
