#requires -Version 5.1
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${logRoot} = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'logs'
${verifyLog} = Join-Path ${logRoot} 'verify\nssm-verify.log'
${smokeFile} = Join-Path ${logRoot} 'smoke\nssm-smoke.txt'
${nssmExe} = 'C:\Program Files\nssm\nssm.exe'
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${verifyLog}) -ErrorAction SilentlyContinue
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
Set-Content -Path ${smokeFile} -Value 'nssm_ok' -Encoding UTF8
exit 0
