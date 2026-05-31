#requires -Version 5.1
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts predate it and probe optional properties
${verifyLog} = Get-MastVerifyLog -Module 'nomachine'
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
Write-MastSmokeOk -Module 'nomachine' | Out-Null
exit 0
