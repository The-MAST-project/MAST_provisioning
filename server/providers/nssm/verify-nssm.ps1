#requires -Version 5.1
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts predate it and probe optional properties
${verifyLog} = Get-MastVerifyLog -Module 'nssm'
${nssmExe} = 'C:\Program Files\nssm\nssm.exe'
if (-not (Test-Path -LiteralPath ${nssmExe})) {
    ("nssm.exe not found: {0}" -f ${nssmExe}) | Out-File -FilePath ${verifyLog} -Encoding UTF8
    exit 1
}
# nssm.exe writes its banner to stderr. With ErrorAction Stop, "& nssm 2>&1" turns stderr
# into ErrorRecords and aborts the script. Use Start-Process with separate redirects.
${so} = Join-Path ${env:TEMP} ('nssm-verify-out-{0}.txt' -f [guid]::NewGuid().ToString('n'))
${se} = Join-Path ${env:TEMP} ('nssm-verify-err-{0}.txt' -f [guid]::NewGuid().ToString('n'))
try {
    # Do not pass -ArgumentList @(): PS 5.1 Start-Process rejects an empty argument list.
    ${null} = Start-Process -FilePath ${nssmExe} -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput ${so} -RedirectStandardError ${se}
    ${merged} = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath ${so}) {
        ${null} = ${merged}.AddRange(@(Get-Content -LiteralPath ${so}))
    }
    if (Test-Path -LiteralPath ${se}) {
        ${null} = ${merged}.AddRange(@(Get-Content -LiteralPath ${se}))
    }
    @(${merged}.ToArray()) | Select-Object -First 3 | Out-File -FilePath ${verifyLog} -Encoding UTF8
}
finally {
    Remove-Item -LiteralPath ${so},${se} -Force -ErrorAction SilentlyContinue
}
Write-MastSmokeOk -Module 'nssm' | Out-Null
exit 0
