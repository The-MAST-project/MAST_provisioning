#requires -Version 5.1
# PS3 CLI path must match provide-planewave.ps1. PWI4 path varies by vendor layout.
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts predate it and probe optional properties
${verifyLog} = Get-MastVerifyLog -Module 'planewave'
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
if (${issues}.Count -gt 0) {
    (${issues} -join [Environment]::NewLine) | Out-File -FilePath ${verifyLog} -Encoding UTF8
    exit 1
}
("PlaneWave OK: PWI4={0}" -f ${pwi}) | Out-File -FilePath ${verifyLog} -Encoding UTF8
Write-MastSmokeOk -Module 'planewave' | Out-Null
exit 0
