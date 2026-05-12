#requires -Version 5.1
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${logRoot} = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'logs'
${verifyLog} = Join-Path ${logRoot} 'verify\vcredist2013-verify.log'
${smokeFile} = Join-Path ${logRoot} 'smoke\vcredist2013-smoke.txt'
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${verifyLog}) -ErrorAction SilentlyContinue
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${smokeFile}) -ErrorAction SilentlyContinue

# VC++ 2013 (12.x) does NOT write to VisualStudio\12.0\VC\Runtimes (that is the 2015+ path).
# It only appears in the standard Uninstall hive.
${uninstallRoots} = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

function Find-Vcr2013 {
    param([string]${Arch})
    foreach (${root} in ${uninstallRoots}) {
        ${keys} = Get-ChildItem -LiteralPath ${root} -ErrorAction SilentlyContinue
        foreach (${k} in ${keys}) {
            ${props} = Get-ItemProperty -LiteralPath ${k}.PSPath -ErrorAction SilentlyContinue
            if (${props}.DisplayName -like "*Visual C++*2013*${Arch}*") {
                return ${props}.DisplayName
            }
        }
    }
    return $null
}

${missing} = @()
foreach (${arch} in @('x64', 'x86')) {
    ${found} = Find-Vcr2013 -Arch ${arch}
    if ($null -eq ${found}) {
        ${missing} += ${arch}
        ("VC++ 2013 {0}: not found in Uninstall registry" -f ${arch}) | Out-File -FilePath ${verifyLog} -Encoding UTF8 -Append
    } else {
        ("VC++ 2013 {0}: OK ({1})" -f ${arch}, ${found}) | Out-File -FilePath ${verifyLog} -Encoding UTF8 -Append
    }
}

if (${missing}.Count -gt 0) {
    ("FAIL: missing {0}" -f (${missing} -join ', ')) | Out-File -FilePath ${verifyLog} -Encoding UTF8 -Append
    exit 1
}

"VC++ 2013 (MSVC120) x64 and x86 OK" | Out-File -FilePath ${verifyLog} -Encoding UTF8 -Append
Set-Content -Path ${smokeFile} -Value 'vcredist2013_ok' -Encoding UTF8
exit 0
