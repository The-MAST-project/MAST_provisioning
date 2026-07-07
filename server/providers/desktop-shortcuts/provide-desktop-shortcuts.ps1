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
    [string]${CalibToolPath} = 'C:\ProgramData\MAST\instrument-profiles\calibrate-instruments.ps1',
    [string]${JupyterLauncher} = 'C:\MAST\jupyter\launch-jupyter.cmd'
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
#
# Everything lives under ONE folder -- Desktop\MAST -- with class subfolders and
# a README per folder, so the desktop itself stays clean. Anything loose that
# other installers dropped is swept into MAST\Vendor at the end.
${desktop}  = Join-Path ${env:PUBLIC} 'Desktop'
${mastRoot}   = Join-Path ${desktop} 'MAST'
${dirOps}     = Join-Path ${mastRoot} 'Operations'
${dirSetup}   = Join-Path ${mastRoot} 'Setup and Calibration'
${dirDev}     = Join-Path ${mastRoot} 'Development'
${dirVendor}  = Join-Path ${mastRoot} 'Vendor'
foreach (${d} in @(${desktop}, ${mastRoot}, ${dirOps}, ${dirSetup}, ${dirDev}, ${dirVendor})) {
    New-Item -ItemType Directory -Path ${d} -Force | Out-Null
}

# --- Per-folder README explainers ------------------------------------------
Set-Content -LiteralPath (Join-Path ${mastRoot} 'README.txt') -Encoding ASCII -Value @(
    'MAST unit tools, grouped by purpose:',
    '',
    '  Operations            - day-to-day operator tools (control page, weather, DS9, logs)',
    '  Setup and Calibration - bring-up and per-unit calibration tools; the bootstrap report',
    '  Development           - developer tools (Jupyter)',
    '  Vendor                - shortcuts dropped by third-party installers, swept here',
    '',
    'Each folder has its own README. Provisioning recreates this layout; do not',
    'store personal files here.'
)
Set-Content -LiteralPath (Join-Path ${dirOps} 'README.txt') -Encoding ASCII -Value @(
    'Day-to-day operator tools.',
    '',
    '  MAST Unit (FastAPI) - the unit control page (http://localhost:8000/).',
    '                        The mast-* services must be running (they ship',
    '                        manual-start; bring them up in the wanted order).',
    '  Weather (Meteoblue) - site forecast page.',
    '  SAOImage DS9        - FITS viewer (associated with .fits files).',
    '  MAST Logs           - C:\MAST\logs (provisioning + runtime logs).'
)
Set-Content -LiteralPath (Join-Path ${dirSetup} 'README.txt') -Encoding ASCII -Value @(
    'Bring-up and calibration tools -- typically used once per unit or after',
    'hardware changes.',
    '',
    '  MAST Instrument Calibration - interactive PWI4 COM-port binder. Run after',
    '                                instruments are cabled; safe to re-run',
    '                                (dry-run mode available; refuses to write',
    '                                while PWI4 is open).',
    '  MAST Installation Directory - C:\MAST (repos, logs, staging).',
    '  MAST Bootstrap Report       - machine identity, MAC addresses, and the',
    '                                manual BIOS power checklist from bootstrap.'
)
Set-Content -LiteralPath (Join-Path ${dirDev} 'README.txt') -Encoding ASCII -Value @(
    'Developer tools.',
    '',
    '  Jupyter Notebook - contained under C:\MAST\jupyter (own venv; does not',
    '                     litter the profile). Opens the notebook server and a',
    '                     browser tab.'
)
Set-Content -LiteralPath (Join-Path ${dirVendor} 'README.txt') -Encoding ASCII -Value @(
    'Shortcuts created by third-party installers (Chrome, NoMachine, ...),',
    'swept off the desktop root by provisioning to keep it clean. Safe to use;',
    'safe to delete.'
)

# 1) Local FastAPI control service.
${fastApiPath} = Join-Path ${dirOps} 'MAST Unit (FastAPI).url'
New-MastUrlShortcut -Path ${fastApiPath} -Url ${FastApiUrl}
Write-ShortcutLog ("FastAPI shortcut -> {0}" -f ${FastApiUrl})

# 2) Site weather page (defaults to Neot Smadar; override via -WeatherUrl). The shortcut
# name carries the site label + 'Meteoblue'. If the URL is empty we skip it rather than
# ship a dead shortcut, clearing any stale copy so toggling stays idempotent.
${weatherLabel} = 'Weather (Meteoblue).url'
if (${WeatherSiteName}) { ${weatherLabel} = '{0} Weather (Meteoblue).url' -f ${WeatherSiteName} }
${weatherPath} = Join-Path ${dirOps} ${weatherLabel}
if (${WeatherUrl} -and (${WeatherUrl}.Trim() -ne '')) {
    New-MastUrlShortcut -Path ${weatherPath} -Url ${WeatherUrl}
    Write-ShortcutLog ("Weather shortcut -> {0}" -f ${WeatherUrl})
} else {
    if (Test-Path -LiteralPath ${weatherPath}) { Remove-Item -LiteralPath ${weatherPath} -Force }
    Write-ShortcutLog '[WARN] Weather page URL not configured (-WeatherUrl empty); weather shortcut skipped.'
}

# 3) SAOImage DS9 (installed by the ds9 provider, order 2600, before this one).
${ds9Path} = Join-Path ${dirOps} 'SAOImage DS9.lnk'
if (Test-Path -LiteralPath ${Ds9Exe}) {
    New-MastLnkShortcut -Path ${ds9Path} -Target ${Ds9Exe} -WorkDir (Split-Path -Parent ${Ds9Exe}) -Desc 'SAOImage DS9 astronomical imaging'
    Write-ShortcutLog ("DS9 shortcut -> {0}" -f ${Ds9Exe})
} else {
    Write-ShortcutLog ("[WARN] DS9 exe not found at {0}; DS9 shortcut skipped (ds9 provider not run?)." -f ${Ds9Exe})
}

# 4) MAST logs folder (provisioning + session logs).
${logsPath} = Join-Path ${dirOps} 'MAST Logs.lnk'
New-Item -ItemType Directory -Path ${LogsDir} -Force | Out-Null
New-MastLnkShortcut -Path ${logsPath} -Target ${LogsDir} -Desc 'MAST provisioning and session logs'
Write-ShortcutLog ("Logs folder shortcut -> {0}" -f ${LogsDir})

# 5) Interactive instrument-calibration tool (deployed by the instrument-profiles
# provider, order 1850 < this one). Lets the operator view/dry-run/apply per-unit
# PWI4 COM bindings after the hardware is cabled.
${calibPath} = Join-Path ${dirSetup} 'MAST Instrument Calibration.lnk'
${psExe} = Join-Path ${env:WINDIR} 'System32\WindowsPowerShell\v1.0\powershell.exe'
${calibArgs} = ('-NoExit -ExecutionPolicy Bypass -NoProfile -File "{0}" -Interactive' -f ${CalibToolPath})
New-MastLnkShortcut -Path ${calibPath} -Target ${psExe} -Arguments ${calibArgs} -WorkDir 'C:\ProgramData\MAST\instrument-profiles' -Desc 'Interactive per-unit PWI4 instrument COM calibration'
if (Test-Path -LiteralPath ${CalibToolPath}) { Write-ShortcutLog ("Calibration shortcut -> {0}" -f ${CalibToolPath}) }
else { Write-ShortcutLog ("[WARN] Calibration tool not yet at {0} (instrument-profiles not run?); shortcut created, works once it is." -f ${CalibToolPath}) }

# 6) Jupyter Notebook launcher (deployed by the jupyter provider, order 2050 < this
# one). The launcher keeps all Jupyter state under C:\MAST\jupyter so it does not
# litter the profile; the shortcut opens the notebook server + browser.
${jupyterPath} = Join-Path ${dirDev} 'Jupyter Notebook.lnk'
${jupyterWorkDir} = Split-Path -Parent ${JupyterLauncher}
${jupyterNotebooks} = Join-Path (Split-Path -Parent ${JupyterLauncher}) 'notebooks'
if (Test-Path -LiteralPath ${jupyterNotebooks}) { ${jupyterWorkDir} = ${jupyterNotebooks} }
New-MastLnkShortcut -Path ${jupyterPath} -Target ${JupyterLauncher} -WorkDir ${jupyterWorkDir} -Desc 'Jupyter Notebook (MAST; state kept under C:\MAST\jupyter)'
if (Test-Path -LiteralPath ${JupyterLauncher}) { Write-ShortcutLog ("Jupyter shortcut -> {0}" -f ${JupyterLauncher}) }
else { Write-ShortcutLog ("[WARN] Jupyter launcher not yet at {0} (jupyter provider not run?); shortcut created, works once it is." -f ${JupyterLauncher}) }

# 7) Installation directory shortcut (bootstrap also creates one at the desktop
# root pre-provisioning; the canonical copy lives here).
${installDirPath} = Join-Path ${dirSetup} 'MAST Installation Directory.lnk'
New-MastLnkShortcut -Path ${installDirPath} -Target 'C:\MAST' -Desc 'MAST installation directory (repos, logs, staging)'
Write-ShortcutLog 'Installation-directory shortcut -> C:\MAST'

# --- Relocate bootstrap artifacts + drop legacy loose copies ----------------
# Bootstrap runs before this layout exists, so its artifacts land at the
# desktop root; adopt them into Setup and Calibration.
${bootstrapReport} = Join-Path ${desktop} 'MAST Bootstrap Report.txt'
if (Test-Path -LiteralPath ${bootstrapReport}) {
    Move-Item -LiteralPath ${bootstrapReport} -Destination (Join-Path ${dirSetup} 'MAST Bootstrap Report.txt') -Force
    Write-ShortcutLog 'Adopted bootstrap report into Setup and Calibration.'
}
${legacyNames} = @(
    'MAST Unit (FastAPI).url', 'SAOImage DS9.lnk', 'MAST Logs.lnk',
    'MAST Instrument Calibration.lnk', 'Jupyter Notebook.lnk',
    'MAST Installation Directory.lnk'
)
foreach (${n} in ${legacyNames}) {
    ${p} = Join-Path ${desktop} ${n}
    if (Test-Path -LiteralPath ${p}) { Remove-Item -LiteralPath ${p} -Force; Write-ShortcutLog ("Removed legacy loose shortcut: {0}" -f ${n}) }
}
foreach (${w} in @(Get-ChildItem -LiteralPath ${desktop} -Filter '*Weather (Meteoblue).url' -File -ErrorAction SilentlyContinue)) {
    Remove-Item -LiteralPath ${w}.FullName -Force
    Write-ShortcutLog ("Removed legacy loose shortcut: {0}" -f ${w}.Name)
}

# --- Vendor sweep: nothing loose stays on the desktop roots -----------------
# Third-party installers (Chrome, NoMachine, ImDisk, ...) drop shortcuts at the
# desktop root; sweep them into MAST\Vendor. Applies to the Public desktop and
# to the mast account's own desktop (provisioning runs as mast).
${sweepRoots} = @(${desktop})
${mastUserDesktop} = 'C:\Users\mast\Desktop'
if ((Test-Path -LiteralPath ${mastUserDesktop}) -and (${mastUserDesktop} -ne ${desktop})) {
    ${sweepRoots} += ${mastUserDesktop}
}
foreach (${root} in ${sweepRoots}) {
    foreach (${item} in @(Get-ChildItem -LiteralPath ${root} -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.lnk', '.url') })) {
        ${dest} = Join-Path ${dirVendor} ${item}.Name
        Move-Item -LiteralPath ${item}.FullName -Destination ${dest} -Force
        Write-ShortcutLog ("Swept loose shortcut into Vendor: {0} (from {1})" -f ${item}.Name, ${root})
    }
}

Write-ShortcutLog 'Desktop shortcuts provisioning complete.'
exit 0
