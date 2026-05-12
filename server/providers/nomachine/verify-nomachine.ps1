#requires -Version 5.1
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${logRoot} = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'logs'
${verifyLog} = Join-Path ${logRoot} 'verify\nomachine-verify.log'
${smokeFile} = Join-Path ${logRoot} 'smoke\nomachine-smoke.txt'
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${verifyLog}) -ErrorAction SilentlyContinue
${svcMatches} = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
        ($PSItem.DisplayName -match 'NoMachine') -or ($PSItem.Name -match 'nx')
    })
if (${svcMatches}.Count -lt 1) {
    'NoMachine-related Windows service not found (expected nx* or display name containing NoMachine).' |
        Out-File -FilePath ${verifyLog} -Encoding UTF8
    exit 1
}
${svcMatches} | Select-Object Name, Status, DisplayName | Format-Table -AutoSize | Out-String |
    Out-File -FilePath ${verifyLog} -Encoding UTF8
if (Test-Path -LiteralPath 'C:\ProgramData\NoMachine\licenses') {
    (Get-ChildItem -LiteralPath 'C:\ProgramData\NoMachine\licenses' -Filter '*.lic' -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Name) | Out-File -FilePath ${verifyLog} -Append -Encoding UTF8
}
Set-Content -Path ${smokeFile} -Value 'nomachine_ok' -Encoding UTF8
exit 0
