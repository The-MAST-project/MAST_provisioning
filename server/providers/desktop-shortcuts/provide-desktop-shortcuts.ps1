param(
    # Site weather page. Defaults to the Neot Smadar (meteoblue) forecast -- the one
    # operational MAST site today. Per-site selection will move to the unit config-file
    # mechanism (open PR: C:/MAST/mast-config-db.json + MongoDB units), not a hostname-
    # derived site map. Override or clear via -WeatherUrl when that lands. NOTE: the URL
    # keeps the meteoblue 'semadar' slug; only the WeatherSiteName label uses 'Smadar'.
    [string]${WeatherUrl} = 'https://www.meteoblue.com/en/weather/today/ne%e2%80%99ot-semadar_israel_8346527',
    # Site name shown in the weather shortcut label (consistent 'Smadar' spelling).
    [string]${WeatherSiteName} = 'Neot Smadar',
    [string]${FastApiUrl} = 'http://localhost:8000/',
    [string]${Ds9Exe}     = 'C:\Program Files\SAOImageDS9\ds9.exe',
    [string]${LogsDir}    = 'C:\MAST\logs',
    [string]${CalibToolPath} = 'C:\ProgramData\MAST\instrument-profiles\calibrate-instruments.ps1'
)

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} 'desktop-shortcuts.log'

function Write-ShortcutLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-desktop-shortcuts.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

function New-MastUrlShortcut {
    param([string]${Path}, [string]${Url})
    # .url is an INI-format Internet Shortcut; writing the two lines directly is
    # more reliable than the WScript URL-shortcut object and keeps the file ASCII.
    Set-Content -LiteralPath ${Path} -Encoding ASCII -Value @('[InternetShortcut]', ('URL=' + ${Url}))
}

function New-MastLnkShortcut {
    param([string]${Path}, [string]${Target}, [string]${WorkDir} = '', [string]${Desc} = '', [string]${Arguments} = '')
    ${wsh} = New-Object -ComObject WScript.Shell
    ${sc}  = ${wsh}.CreateShortcut(${Path})
    ${sc}.TargetPath = ${Target}
    if (${Arguments}) { ${sc}.Arguments = ${Arguments} }
    if (${WorkDir}) { ${sc}.WorkingDirectory = ${WorkDir} }
    if (${Desc})    { ${sc}.Description = ${Desc} }
    ${sc}.Save()
}

# Public (all-users) desktop: shortcuts show for any account that signs in,
# including the autologin 'mast' account. Account-agnostic, mirroring the HKLM
# all-users file association the ds9 provider sets.
${desktop} = Join-Path ${env:PUBLIC} 'Desktop'
New-Item -ItemType Directory -Path ${desktop} -Force | Out-Null

# 1) Local FastAPI control service.
${fastApiPath} = Join-Path ${desktop} 'MAST Unit (FastAPI).url'
New-MastUrlShortcut -Path ${fastApiPath} -Url ${FastApiUrl}
Write-ShortcutLog ("FastAPI shortcut -> {0}" -f ${FastApiUrl})

# 2) Site weather page (defaults to Neot Smadar; override via -WeatherUrl). The shortcut
# name carries the site label + 'Meteoblue'. If the URL is empty we skip it rather than
# ship a dead shortcut, clearing any stale copy so toggling stays idempotent.
${weatherLabel} = 'Weather (Meteoblue).url'
if (${WeatherSiteName}) { ${weatherLabel} = '{0} Weather (Meteoblue).url' -f ${WeatherSiteName} }
${weatherPath} = Join-Path ${desktop} ${weatherLabel}
if (${WeatherUrl} -and (${WeatherUrl}.Trim() -ne '')) {
    New-MastUrlShortcut -Path ${weatherPath} -Url ${WeatherUrl}
    Write-ShortcutLog ("Weather shortcut -> {0}" -f ${WeatherUrl})
} else {
    if (Test-Path -LiteralPath ${weatherPath}) { Remove-Item -LiteralPath ${weatherPath} -Force }
    Write-ShortcutLog '[WARN] Weather page URL not configured (-WeatherUrl empty); weather shortcut skipped.'
}

# 3) SAOImage DS9 (installed by the ds9 provider, order 2600, before this one).
${ds9Path} = Join-Path ${desktop} 'SAOImage DS9.lnk'
if (Test-Path -LiteralPath ${Ds9Exe}) {
    New-MastLnkShortcut -Path ${ds9Path} -Target ${Ds9Exe} -WorkDir (Split-Path -Parent ${Ds9Exe}) -Desc 'SAOImage DS9 astronomical imaging'
    Write-ShortcutLog ("DS9 shortcut -> {0}" -f ${Ds9Exe})
} else {
    Write-ShortcutLog ("[WARN] DS9 exe not found at {0}; DS9 shortcut skipped (ds9 provider not run?)." -f ${Ds9Exe})
}

# 4) MAST logs folder (provisioning + session logs).
${logsPath} = Join-Path ${desktop} 'MAST Logs.lnk'
New-Item -ItemType Directory -Path ${LogsDir} -Force | Out-Null
New-MastLnkShortcut -Path ${logsPath} -Target ${LogsDir} -Desc 'MAST provisioning and session logs'
Write-ShortcutLog ("Logs folder shortcut -> {0}" -f ${LogsDir})

# 5) Interactive instrument-calibration tool (deployed by the instrument-profiles
# provider, order 1850 < this one). Lets the operator view/dry-run/apply per-unit
# PWI4 COM bindings after the hardware is cabled.
${calibPath} = Join-Path ${desktop} 'MAST Instrument Calibration.lnk'
${psExe} = Join-Path ${env:WINDIR} 'System32\WindowsPowerShell\v1.0\powershell.exe'
${calibArgs} = ('-NoExit -ExecutionPolicy Bypass -NoProfile -File "{0}" -Interactive' -f ${CalibToolPath})
New-MastLnkShortcut -Path ${calibPath} -Target ${psExe} -Arguments ${calibArgs} -WorkDir 'C:\ProgramData\MAST\instrument-profiles' -Desc 'Interactive per-unit PWI4 instrument COM calibration'
if (Test-Path -LiteralPath ${CalibToolPath}) { Write-ShortcutLog ("Calibration shortcut -> {0}" -f ${CalibToolPath}) }
else { Write-ShortcutLog ("[WARN] Calibration tool not yet at {0} (instrument-profiles not run?); shortcut created, works once it is." -f ${CalibToolPath}) }
Write-ShortcutLog 'Desktop shortcuts provisioning complete.'
exit 0
