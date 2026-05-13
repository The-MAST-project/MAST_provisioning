#requires -Version 5.1
# PS3 CLI path must match provide-planewave.ps1. PWI4 path varies by vendor layout.
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${logRoot} = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'logs'
${verifyLog} = Join-Path ${logRoot} 'verify\planewave-verify.log'
${smokeFile} = Join-Path ${logRoot} 'smoke\planewave-smoke.txt'
${ps3cliPath} = 'C:\Users\mast\Documents\PlaneWave\ps3cli'
${pwiCandidates} = @(
    'C:\Program Files (x86)\PlaneWave Instruments\PlaneWave Interface 4\PWI4.exe',
    'C:\Program Files\PlaneWave Instruments\PlaneWave Interface 4\PWI4.exe',
    'C:\Program Files\PlaneWave Instruments\PWI4\pwi4.exe',
    'C:\Program Files (x86)\PlaneWave Instruments\PWI4\pwi4.exe'
)
${pwi} = $null
foreach (${c} in ${pwiCandidates}) {
    if (Test-Path -LiteralPath ${c}) {
        ${pwi} = ${c}
        break
    }
}
${issues} = New-Object 'System.Collections.Generic.List[string]'
if (-not ${pwi}) {
    [void]${issues}.Add('PWI4.exe not found under expected PlaneWave paths.')
}
${pwi4Svc} = Get-Service -Name 'PWI4' -ErrorAction SilentlyContinue
if ($null -eq ${pwi4Svc}) {
    [void]${issues}.Add('PWI4 service not registered')
} elseif (${pwi4Svc}.Status -ne 'Running') {
    [void]${issues}.Add(("PWI4 service registered but not running (status={0})" -f ${pwi4Svc}.Status))
}
if (-not (Test-Path -LiteralPath ${ps3cliPath})) {
    [void]${issues}.Add("PS3 CLI directory missing: ${ps3cliPath}")
}
else {
    ${any} = Get-ChildItem -LiteralPath ${ps3cliPath} -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not ${any}) {
        [void]${issues}.Add("PS3 CLI directory empty: ${ps3cliPath}")
    }
}
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${verifyLog}) -ErrorAction SilentlyContinue
if (${issues}.Count -gt 0) {
    (${issues} -join [Environment]::NewLine) | Out-File -FilePath ${verifyLog} -Encoding UTF8
    exit 1
}
("PlaneWave OK: PWI4={0}" -f ${pwi}) | Out-File -FilePath ${verifyLog} -Encoding UTF8
Set-Content -Path ${smokeFile} -Value 'planewave_ok' -Encoding UTF8
exit 0
