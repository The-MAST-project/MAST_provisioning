#requires -Version 5.1
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts predate it and probe optional properties
${verifyLog} = Get-MastVerifyLog -Module 'vcredist2013'

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
Write-MastSmokeOk -Module 'vcredist2013' | Out-Null
exit 0
