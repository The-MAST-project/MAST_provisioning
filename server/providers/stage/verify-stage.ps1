#requires -Version 5.1
# Must match provide-stage.ps1 (XILab / xilab.exe locations).
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${logRoot} = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'logs'
${verifyLog} = Join-Path ${logRoot} 'verify\stage-verify.log'
${smokeFile} = Join-Path ${logRoot} 'smoke\stage-smoke.txt'
${candidates} = @(
    'C:\Program Files\XILab\XILab.exe',
    'C:\Program Files (x86)\XILab\XILab.exe'
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
    ('xilab.exe not found (checked: {0})' -f (${candidates} -join '; ')) | Out-File -FilePath ${verifyLog} -Encoding UTF8
    exit 1
}
("Stage (XILab) OK: {0}" -f ${found}) | Out-File -FilePath ${verifyLog} -Encoding UTF8
Set-Content -Path ${smokeFile} -Value 'stage_ok' -Encoding UTF8
exit 0
