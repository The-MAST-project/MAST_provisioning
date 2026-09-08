param(
    # Site weather page. Defaults to the Neot Smadar (meteoblue) forecast -- the one
    # operational MAST site today. Per-site selection will move to the unit config-file
    # mechanism (open PR: C:/MAST/mast-config-db.json + MongoDB units), not a hostname-
    # derived site map. Override or clear via -WeatherUrl when that lands. NOTE: the URL
    # keeps the meteoblue 'semadar' slug; only the WeatherSiteName label uses 'Smadar'.
    [string]${WeatherUrl} = 'https://www.meteoblue.com/en/weather/today/ne%e2%80%99ot-semadar_israel_8346527',
    # Site name shown in the weather shortcut label (consistent 'Smadar' spelling).
    [string]${WeatherSiteName} = 'Neot Smadar',
    [string]${FastApiUrl} = 'http://localhost:8000/docs',
    # MAST's own Grafana, on the site controller. Addressed by host and port
    # rather than through that host's nginx: its vhost redirects everything to
    # the canonical FQDN over HTTPS, behind a certificate from a local CA a unit
    # has no reason to trust, and none of that is worth a browser warning for a
    # dashboard. The per-host selector is appended below.
    [string]${GrafanaUrl} = 'http://mast-ns-control:3000/grafana/d/IV0hu1m7z/windows-exporter-dashboard',
    # The LAST observatory's Grafana on last0, which carries the site's weather
    # sensors and the safety view. A different host, a different Grafana, and
    # not ours -- linked, never proxied or embedded: it sends
    # X-Frame-Options: deny, serves no TLS, and answers 401 to anonymous, so a
    # link in a new tab is the only form of it that works at all today.
    [string]${SafetyUrl} = 'http://10.23.1.25:3000/grafana/d/dk8DxsWVz/neot-smadar-weather?orgId=1&refresh=10s',
    [string]${Ds9Exe}     = 'C:\Program Files\SAOImageDS9\ds9.exe',
    [string]${LogsDir}    = 'C:\MAST\logs',
    [string]${CalibToolPath} = 'C:\ProgramData\MAST\instrument-profiles\calibrate-instruments.ps1',
    [string]${JupyterLauncher} = 'C:\MAST\jupyter\launch-jupyter.cmd',
    # Clone top, the same value module.json hands the 'mast' provider. The VS Code
    # multi-root workspace is found by glob underneath it.
    [string]${CloneTop} = 'C:\MAST\src'
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

<#
Desktop\MAST is REBUILT, not migrated.

Every file under it is derived state -- a shortcut to something installed
elsewhere, or a README this script writes -- so the run clears the tree and
builds it again rather than accumulating a migration block per change. A folder
rename then needs no adopt-and-remove step, and none of those steps survives as
dead code once the fleet has converted.

Two consequences the rebuild has to respect:

  - The CONTENTS are cleared, not the folder. An Explorer window sitting on
    Desktop\MAST holds the directory itself, and a recursive remove of it would
    fail the module and the run. Its children are not held that way.

  - Vendor survives the clear. It is the one folder holding files this script
    did not make: a shortcut swept there came from a third-party installer that
    has already run and skips on re-run, so wiping it destroys something nothing
    can recreate. Only the names this provider has since promoted into a class
    folder are pruned out of it.

  - A vendor shortcut that this script promotes into a class folder is CREATED
    from the resolved exe, never inherited from the sweep. A swept .lnk cannot
    be recreated after a wipe: a third-party installer made it, and every vendor
    provider is idempotent (chrome skips on chrome.exe, zwo on ASIStudio.exe,
    vscode on Code.exe), so nothing would put it back. Paths are resolved at run
    time and a missing tool is a warning, not a failure -- the fleet does vary.
#>

# ---------------------------------------------------------------------------
# Shortcut primitives
# ---------------------------------------------------------------------------
function New-MastUrlShortcut {
    param([string]${Path}, [string]${Url})
    # .url is an INI-format Internet Shortcut; writing the two lines directly is
    # more reliable than the WScript URL-shortcut object and keeps the file ASCII.
    Set-Content -LiteralPath ${Path} -Encoding ASCII -Value @('[InternetShortcut]', ('URL=' + ${Url}))
}

function New-MastLnkShortcut {
    param(
        [string]${Path}, [string]${Target}, [string]${WorkDir} = '', [string]${Desc} = '',
        [string]${Arguments} = '', [string]${IconLocation} = ''
    )
    ${wsh} = New-Object -ComObject WScript.Shell
    ${sc}  = ${wsh}.CreateShortcut(${Path})
    ${sc}.TargetPath = ${Target}
    if (${Arguments})    { ${sc}.Arguments = ${Arguments} }
    if (${WorkDir})      { ${sc}.WorkingDirectory = ${WorkDir} }
    if (${Desc})         { ${sc}.Description = ${Desc} }
    if (${IconLocation}) { ${sc}.IconLocation = ${IconLocation} }
    ${sc}.Save()
}

${chromeExe} = 'C:\Program Files\Google\Chrome\Application\chrome.exe'

function New-MastBrowserShortcut {
    <#
      A web page an operator opens, launched through Chrome rather than handed to
      the shell. Nothing in provisioning sets a default browser, and on a unit the
      http association resolves to IE (ProgId IE.HTTP), which cannot render the
      Swagger page at all. Chrome is order 2100, well ahead of this provider.

      Falls back to a plain .url when chrome.exe is absent: a shortcut that opens
      in the wrong browser still opens, where a .lnk to a missing exe is dead.
      Every one of these needs its own IconLocation or the folder shows a row of
      identical Chrome icons.
    #>
    param([string]${Dir}, [string]${Name}, [string]${Url}, [string]${Desc} = '', [string]${IconLocation} = '')
    if (Test-Path -LiteralPath ${chromeExe}) {
        New-MastLnkShortcut -Path (Join-Path ${Dir} ("{0}.lnk" -f ${Name})) -Target ${chromeExe} `
            -Arguments ${Url} -WorkDir (Split-Path -Parent ${chromeExe}) -Desc ${Desc} -IconLocation ${IconLocation}
        return ("{0}.lnk" -f ${Name})
    }
    Write-ShortcutLog ("[WARN] chrome.exe not found at {0}; '{1}' falls back to a .url opened by the default browser." -f ${chromeExe}, ${Name})
    New-MastUrlShortcut -Path (Join-Path ${Dir} ("{0}.url" -f ${Name})) -Url ${Url}
    return ("{0}.url" -f ${Name})
}

function Add-MastUrlQuery {
    param([string]${Url}, [string]${Query})
    if (-not ${Query}) { return ${Url} }
    ${sep} = '?'
    if (${Url} -match '\?') { ${sep} = '&' }
    return ('{0}{1}{2}' -f ${Url}, ${sep}, ${Query})
}

function Resolve-MastAppPath {
    # First candidate that exists, or '' -- the vendor tools sit under either
    # Program Files root depending on installer bitness, and two are per-user.
    param([string[]]${Candidates})
    foreach (${c} in ${Candidates}) {
        if (${c} -and (Test-Path -LiteralPath ${c})) { return ${c} }
    }
    return ''
}

function Find-MastFileUnder {
    # Single match under one root, or '' -- used where the filename is derived
    # rather than fixed (the mast-clone workspace) or the install root varies
    # (VS Code UserSetup lands in the running account's LOCALAPPDATA).
    param([string[]]${Roots}, [string]${Filter}, [switch]${Recurse})
    ${hits} = @()
    foreach (${r} in ${Roots}) {
        if (-not (Test-Path -LiteralPath ${r})) { continue }
        ${hits} += @(Get-ChildItem -LiteralPath ${r} -Filter ${Filter} -File -Recurse:${Recurse} -ErrorAction SilentlyContinue)
    }
    if (${hits}.Count -eq 1) { return ${hits}[0].FullName }
    if (${hits}.Count -eq 0) { return '' }
    Write-ShortcutLog ("[WARN] {0} matched {1} files ({2}); not guessing." -f ${Filter}, ${hits}.Count, ((${hits} | ForEach-Object { $_.FullName }) -join ', '))
    return ''
}

# ---------------------------------------------------------------------------
# The layout
# ---------------------------------------------------------------------------
# Public (all-users) desktop: shortcuts show for any account that signs in,
# including the autologin 'mast' account. Account-agnostic, mirroring the HKLM
# all-users file association the ds9 provider sets.
#
# 'MAST Unit Operation' is everything a normal operator touches -- including the
# instrument and viewer applications, which sat in Vendor only because their
# installers dropped them loose. Setup and Calibration is per-unit bring-up,
# Development signals a development mindset by its name, and Vendor is left for
# genuine strays.
${desktop}      = Join-Path ${env:PUBLIC} 'Desktop'
${mastRoot}     = Join-Path ${desktop} 'MAST'
${dirOperation} = Join-Path ${mastRoot} 'MAST Unit Operation'
${dirSetup}     = Join-Path ${mastRoot} 'Setup and Calibration'
${dirDev}       = Join-Path ${mastRoot} 'Development'
${dirVendor}    = Join-Path ${mastRoot} 'Vendor'

${imageres}     = Join-Path ${env:WINDIR} 'System32\imageres.dll'
${psExe}        = Join-Path ${env:WINDIR} 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Names this provider owns, filled in as they are created. The sweep DELETES a
# loose copy of one of these off a desktop root rather than moving it into
# Vendor: bootstrap writes 'MAST Installation Directory.lnk' there before this
# layout exists, and sweeping it would leave a duplicate of a shortcut the
# rebuild has already placed.
${ownedNames} = New-Object 'System.Collections.Generic.List[string]'
function Register-MastOwnedName { param([string]${Name}) if (${Name}) { [void]${ownedNames}.Add(${Name}) } }

# ---------------------------------------------------------------------------
# Clear
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Path ${desktop} -Force | Out-Null
New-Item -ItemType Directory -Path ${mastRoot} -Force | Out-Null
# Vendor is the one folder that is NOT derived, so it is the one folder the
# rebuild keeps. Everything in the class folders is created here from something
# installed elsewhere, but a Vendor shortcut was made by a third-party installer
# that has already run and is idempotent -- delete it and nothing brings it
# back. Its own contents are pruned further down, once the owned-name list is
# complete: a tool promoted into a class folder must not also linger here.
foreach (${child} in @(Get-ChildItem -LiteralPath ${mastRoot} -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'Vendor' })) {
    Remove-Item -LiteralPath ${child}.FullName -Recurse -Force
}
Write-ShortcutLog ("Cleared {0} for rebuild (Vendor kept)." -f ${mastRoot})

foreach (${d} in @(${dirOperation}, ${dirSetup}, ${dirDev}, ${dirVendor})) {
    New-Item -ItemType Directory -Path ${d} -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Per-folder READMEs
# ---------------------------------------------------------------------------
Set-Content -LiteralPath (Join-Path ${mastRoot} 'README.txt') -Encoding ASCII -Value @(
    'MAST unit tools, grouped by purpose:',
    '',
    '  MAST Unit Operation   - everything used to run the unit: its API page,',
    '                          dashboards, weather, viewers, PWI4, logs',
    '  Setup and Calibration - bring-up and per-unit calibration tools',
    '  Development           - the source tree, editor and notebooks',
    '  Vendor                - shortcuts dropped by third-party installers, swept here',
    '',
    'Each folder has its own README. Provisioning REBUILDS this layout from',
    'scratch on every run: anything you add to a folder above is removed, and',
    'anything you delete comes back. Vendor is the exception -- it keeps what',
    'installers left. Keep personal files somewhere else.'
)
Set-Content -LiteralPath (Join-Path ${dirOperation} 'README.txt') -Encoding ASCII -Value @(
    'Everything used to operate the unit.',
    '',
    '  MAST Unit (FastAPI) - the unit API contract page, grouped by contract',
    '                        tier (http://localhost:8000/docs). The bare root used',
    '                        to be the target and answered 404. The unit service',
    '                        must be running.',
    '  MAST Unit Metrics   - this unit windows_exporter metrics, on the site',
    '    (Grafana)           controller Grafana, with the host selector already',
    '                        pointed at this machine.',
    '  Sensors and Safety  - the site weather sensors and the observatory safety',
    '    (Grafana)           view. A DIFFERENT Grafana, on the LAST observatory',
    '                        host, and not ours: it asks for its own login, which',
    '                        is theirs to grant.',
    '  Weather (Meteoblue) - site forecast page. The public forecast, as opposed',
    '                        to the live sensors above.',
    '  SAOImage DS9        - FITS viewer (associated with .fits files).',
    '  MAST Logs           - C:\MAST\logs (provisioning + runtime logs).',
    '  PlaneWave Interface 4 - mount, focuser and covers.',
    '  ASICap              - ZWO camera capture.',
    '  NoMachine           - remote desktop client.',
    '  Google Chrome       - the browser the web shortcuts here open in.',
    '',
    'Web shortcuts here are .lnk files that launch Chrome directly. Nothing in',
    'provisioning sets a default browser and the unit resolves http to IE, which',
    'cannot render the Swagger page.',
    '',
    'Both Grafana links reach 10.23.1.x on port 3000, so they need the proxy',
    'bypass that covers the MAST subnets; a unit provisioned before that shipped',
    'will see them time out rather than fail.'
)
Set-Content -LiteralPath (Join-Path ${dirSetup} 'README.txt') -Encoding ASCII -Value @(
    'Bring-up and calibration tools -- typically used once per unit or after',
    'hardware changes.',
    '',
    '  MAST Instrument Calibration - interactive PWI4 COM-port binder. Run after',
    '                                instruments are cabled; safe to re-run',
    '                                (dry-run mode available; refuses to write',
    '                                while PWI4 is open).',
    '  MAST Proxy                  - view and toggle the unit proxy posture',
    '                                (Weizmann / direct) across all surfaces.',
    '  XILab, ASIMount,            - instrument vendor tools used while bringing',
    '  ASCOM Diagnostics             hardware up or diagnosing it.'
)
Set-Content -LiteralPath (Join-Path ${dirDev} 'README.txt') -Encoding ASCII -Value @(
    'Developer tools. Opening anything here means working on the unit software,',
    'not operating the unit.',
    '',
    '  MAST Unit Workspace         - the multi-root VS Code workspace mast-clone',
    '                                writes. The only arrangement in which each',
    '                                repo keeps its own settings.json and',
    '                                launch.json; opening C:\MAST\src as a plain',
    '                                folder ignores all of them.',
    '  Visual Studio Code          - the bare editor.',
    '  Jupyter Notebook            - contained under C:\MAST\jupyter (own venv).',
    '  MongoDB Compass             - the config DB GUI.',
    '  MAST Installation Directory - C:\MAST (repos, logs, staging).',
    '',
    'VS Code and Compass install per-user, into the mast profile. Their shortcuts',
    'are on the all-users desktop but only resolve for the mast account, which is',
    'the account a unit logs in as.'
)
Set-Content -LiteralPath (Join-Path ${dirVendor} 'README.txt') -Encoding ASCII -Value @(
    'Shortcuts created by third-party installers that MAST has no particular use',
    'for, swept off the desktop root by provisioning to keep it clean.',
    '',
    'Unlike the folders beside it, this one is NOT rebuilt: the installers that',
    'made these are idempotent and will not run again, so a deleted shortcut here',
    'does not come back. Delete one only if you mean it.'
)

# ---------------------------------------------------------------------------
# MAST's own shortcuts
# ---------------------------------------------------------------------------
Register-MastOwnedName (New-MastBrowserShortcut -Dir ${dirOperation} -Name 'MAST Unit (FastAPI)' -Url ${FastApiUrl} `
    -Desc 'The unit API contract page' -IconLocation ("{0},175" -f ${imageres}))
Write-ShortcutLog ("FastAPI shortcut -> {0}" -f ${FastApiUrl})

# Skipped rather than shipped dead when the URL is cleared; the rebuild means
# there is no stale copy to remove first.
${weatherName} = 'Weather (Meteoblue)'
if (${WeatherSiteName}) { ${weatherName} = '{0} Weather (Meteoblue)' -f ${WeatherSiteName} }
if (${WeatherUrl} -and (${WeatherUrl}.Trim() -ne '')) {
    Register-MastOwnedName (New-MastBrowserShortcut -Dir ${dirOperation} -Name ${weatherName} -Url ${WeatherUrl} `
        -Desc 'Site weather forecast' -IconLocation ("{0},138" -f ${imageres}))
    Write-ShortcutLog ("Weather shortcut -> {0}" -f ${WeatherUrl})
} else {
    Write-ShortcutLog '[WARN] Weather page URL not configured (-WeatherUrl empty); weather shortcut skipped.'
}

# This unit's own metrics. The dashboard picks a host with its 'server' template
# variable, whose values are Prometheus instance labels: LOWERCASE hostname plus
# the exporter port. COMPUTERNAME is upper case on Windows and would match no
# option in that list, quietly leaving the operator on whichever host Grafana
# defaults to -- which is the failure that looks like it worked.
if (${GrafanaUrl} -and (${GrafanaUrl}.Trim() -ne '')) {
    ${metricsUrl} = Add-MastUrlQuery -Url ${GrafanaUrl} -Query ('var-server={0}:9182' -f ${env:COMPUTERNAME}.ToLower())
    Register-MastOwnedName (New-MastBrowserShortcut -Dir ${dirOperation} -Name 'MAST Unit Metrics (Grafana)' -Url ${metricsUrl} `
        -Desc 'windows_exporter metrics for this unit' -IconLocation ("{0},144" -f ${imageres}))
    Write-ShortcutLog ("Unit metrics shortcut -> {0}" -f ${metricsUrl})
} else {
    Write-ShortcutLog '[WARN] -GrafanaUrl empty; unit metrics shortcut skipped.'
}

${safetyName} = 'Sensors and Safety (Grafana)'
if (${WeatherSiteName}) { ${safetyName} = '{0} Sensors and Safety (Grafana)' -f ${WeatherSiteName} }
if (${SafetyUrl} -and (${SafetyUrl}.Trim() -ne '')) {
    Register-MastOwnedName (New-MastBrowserShortcut -Dir ${dirOperation} -Name ${safetyName} -Url ${SafetyUrl} `
        -Desc 'Site weather sensors and the observatory safety view (LAST observatory Grafana)' `
        -IconLocation ("{0},101" -f ${imageres}))
    Write-ShortcutLog ("Sensors and safety shortcut -> {0}" -f ${SafetyUrl})
} else {
    Write-ShortcutLog '[WARN] -SafetyUrl empty; sensors and safety shortcut skipped.'
}

if (Test-Path -LiteralPath ${Ds9Exe}) {
    New-MastLnkShortcut -Path (Join-Path ${dirOperation} 'SAOImage DS9.lnk') -Target ${Ds9Exe} `
        -WorkDir (Split-Path -Parent ${Ds9Exe}) -Desc 'SAOImage DS9 astronomical imaging'
    Register-MastOwnedName 'SAOImage DS9.lnk'
    Write-ShortcutLog ("DS9 shortcut -> {0}" -f ${Ds9Exe})
} else {
    Write-ShortcutLog ("[WARN] DS9 exe not found at {0}; DS9 shortcut skipped (ds9 provider not run?)." -f ${Ds9Exe})
}

New-Item -ItemType Directory -Path ${LogsDir} -Force | Out-Null
New-MastLnkShortcut -Path (Join-Path ${dirOperation} 'MAST Logs.lnk') -Target ${LogsDir} `
    -Desc 'MAST provisioning and session logs'
Register-MastOwnedName 'MAST Logs.lnk'
Write-ShortcutLog ("Logs folder shortcut -> {0}" -f ${LogsDir})

# Interactive tools deployed by earlier providers (instrument-profiles at 1850,
# proxy at 100). The shortcut is created either way and works once the tool is
# there; both are well ahead of this provider in a full cycle.
New-MastLnkShortcut -Path (Join-Path ${dirSetup} 'MAST Instrument Calibration.lnk') -Target ${psExe} `
    -Arguments ('-NoExit -ExecutionPolicy Bypass -NoProfile -File "{0}" -Interactive' -f ${CalibToolPath}) `
    -WorkDir 'C:\ProgramData\MAST\instrument-profiles' -Desc 'Interactive per-unit PWI4 instrument COM calibration'
Register-MastOwnedName 'MAST Instrument Calibration.lnk'
if (-not (Test-Path -LiteralPath ${CalibToolPath})) {
    Write-ShortcutLog ("[WARN] Calibration tool not yet at {0} (instrument-profiles not run?); shortcut created, works once it is." -f ${CalibToolPath})
}

${proxyToolPath} = 'C:\ProgramData\MAST\proxy\set-proxy.ps1'
New-MastLnkShortcut -Path (Join-Path ${dirSetup} 'MAST Proxy.lnk') -Target ${psExe} `
    -Arguments ('-NoExit -ExecutionPolicy Bypass -NoProfile -File "{0}" -Interactive' -f ${proxyToolPath}) `
    -WorkDir 'C:\ProgramData\MAST\proxy' -Desc 'View and toggle the unit proxy (Weizmann / direct) across all surfaces'
Register-MastOwnedName 'MAST Proxy.lnk'
if (-not (Test-Path -LiteralPath ${proxyToolPath})) {
    Write-ShortcutLog ("[WARN] Proxy tool not yet at {0} (proxy provider not run?); shortcut created, works once it is." -f ${proxyToolPath})
}

${jupyterWorkDir} = Split-Path -Parent ${JupyterLauncher}
${jupyterNotebooks} = Join-Path ${jupyterWorkDir} 'notebooks'
if (Test-Path -LiteralPath ${jupyterNotebooks}) { ${jupyterWorkDir} = ${jupyterNotebooks} }
New-MastLnkShortcut -Path (Join-Path ${dirDev} 'Jupyter Notebook.lnk') -Target ${JupyterLauncher} `
    -WorkDir ${jupyterWorkDir} -Desc 'Jupyter Notebook (MAST; state kept under C:\MAST\jupyter)'
Register-MastOwnedName 'Jupyter Notebook.lnk'
if (-not (Test-Path -LiteralPath ${JupyterLauncher})) {
    Write-ShortcutLog ("[WARN] Jupyter launcher not yet at {0} (jupyter provider not run?); shortcut created, works once it is." -f ${JupyterLauncher})
}

New-MastLnkShortcut -Path (Join-Path ${dirDev} 'MAST Installation Directory.lnk') -Target 'C:\MAST' `
    -Desc 'MAST installation directory (repos, logs, staging)'
Register-MastOwnedName 'MAST Installation Directory.lnk'
Write-ShortcutLog 'Installation-directory shortcut -> C:\MAST'

# ---------------------------------------------------------------------------
# Third-party tools MAST actually uses, created from the resolved exe
# ---------------------------------------------------------------------------
# Each entry names the folder it belongs in and where its executable can be.
# Anything not listed here is a stray and gets swept into Vendor below.
# UserSetup installs into the RUNNING account's LOCALAPPDATA, which is the mast
# profile during provisioning; module.json's -InstallRoot names Program Files and
# is not where it lands. The workspace shortcut below needs the same path.
${vsCodeCandidates} = @(
    (Join-Path ${env:LOCALAPPDATA} 'Programs\Microsoft VS Code\Code.exe'),
    'C:\Users\mast\AppData\Local\Programs\Microsoft VS Code\Code.exe',
    'C:\Program Files\Microsoft VS Code\Code.exe'
)
${vsCodeExe} = Resolve-MastAppPath ${vsCodeCandidates}

${mappedTools} = @(
    @{ Name = 'PlaneWave Interface 4'; Dir = ${dirOperation}; Desc = 'Mount, focuser and covers';
       Candidates = @('C:\Program Files (x86)\PlaneWave Instruments\PlaneWave Interface 4\PWI4.exe',
                      'C:\Program Files\PlaneWave Instruments\PlaneWave Interface 4\PWI4.exe') }
    # ASICap, not the ASIStudio suite chooser: ASICap is the capture tool used.
    @{ Name = 'ASICap'; Dir = ${dirOperation}; Desc = 'ZWO camera capture';
       Candidates = @('C:\Program Files\ASIStudio\ASICap.exe',
                      'C:\Program Files (x86)\ASIStudio\ASICap.exe') }
    @{ Name = 'NoMachine'; Dir = ${dirOperation}; Desc = 'NoMachine remote desktop client';
       Candidates = @('C:\Program Files\NoMachine\bin\nxplayer.exe');
       Icon = 'C:\Program Files\NoMachine\share\icons\nomachine.ico,0' }
    @{ Name = 'Google Chrome'; Dir = ${dirOperation}; Desc = 'Web browser';
       Candidates = @(${chromeExe}) }
    @{ Name = 'XILab'; Dir = ${dirSetup}; Desc = 'Standa stage control (FCU)';
       Candidates = @('C:\Program Files\XILab\XILab.exe') }
    @{ Name = 'ASIMount'; Dir = ${dirSetup}; Desc = 'ZWO ASCOM mount server';
       Candidates = @('C:\Program Files (x86)\Common Files\ASCOM\ZWO\ASIMount\ASCOM.ASIMount.Server.exe') }
    @{ Name = 'ASCOM Diagnostics'; Dir = ${dirSetup}; Desc = 'ASCOM platform diagnostics';
       Candidates = @('C:\Program Files (x86)\ASCOM\Platform\Tools\ASCOM Diagnostics.exe') }
    @{ Name = 'Visual Studio Code'; Dir = ${dirDev}; Desc = 'Visual Studio Code';
       Candidates = ${vsCodeCandidates} }
    @{ Name = 'MongoDB Compass'; Dir = ${dirDev}; Desc = 'MongoDB GUI (the config DB)';
       Candidates = @((Join-Path ${env:LOCALAPPDATA} 'MongoDBCompass\MongoDBCompass.exe'),
                      'C:\Users\mast\AppData\Local\MongoDBCompass\MongoDBCompass.exe') }
)

foreach (${t} in ${mappedTools}) {
    ${exe} = Resolve-MastAppPath ${t}.Candidates
    ${lnkName} = '{0}.lnk' -f ${t}.Name
    Register-MastOwnedName ${lnkName}
    if (-not ${exe}) {
        ${looked} = @(${t}.Candidates | Where-Object { $_ } | Select-Object -Unique) -join '; '
        Write-ShortcutLog ("[WARN] {0} not installed (looked in: {1}); shortcut skipped." -f ${t}.Name, ${looked})
        continue
    }
    ${icon} = ''
    if (${t}.ContainsKey('Icon') -and (Test-Path -LiteralPath (${t}.Icon -replace ',\d+$', ''))) { ${icon} = ${t}.Icon }
    New-MastLnkShortcut -Path (Join-Path ${t}.Dir ${lnkName}) -Target ${exe} `
        -WorkDir (Split-Path -Parent ${exe}) -Desc ${t}.Desc -IconLocation ${icon}
    Write-ShortcutLog ("{0} -> {1}" -f ${t}.Name, ${exe})
}

# The multi-root workspace, not the bare editor, is what a developer opens: it
# is the only arrangement in which each repo's own .vscode/settings.json and
# launch.json are read. mast-clone derives the filename from the roles it cloned
# and writes it ONLY when absent, because people customise it -- so this follows
# whatever is on disk and never regenerates or repairs it.
${wsName} = 'MAST Unit Workspace.lnk'
Register-MastOwnedName ${wsName}
${workspaceFile} = Find-MastFileUnder -Roots @(${CloneTop}) -Filter 'mast-*.code-workspace'
if (${workspaceFile} -and ${vsCodeExe}) {
    New-MastLnkShortcut -Path (Join-Path ${dirDev} ${wsName}) -Target ${vsCodeExe} `
        -Arguments ('"{0}"' -f ${workspaceFile}) -WorkDir ${CloneTop} `
        -Desc 'The MAST multi-root VS Code workspace'
    Write-ShortcutLog ("Workspace shortcut -> {0}" -f ${workspaceFile})
} elseif (-not ${vsCodeExe}) {
    Write-ShortcutLog '[WARN] VS Code not installed; workspace shortcut skipped.'
} else {
    Write-ShortcutLog ("[WARN] no single mast-*.code-workspace under {0}; workspace shortcut skipped (mast provider not run?)." -f ${CloneTop})
}

# ---------------------------------------------------------------------------
# Sweep: nothing loose stays on the desktop roots
# ---------------------------------------------------------------------------
# Third-party installers drop shortcuts at the desktop root, and bootstrap drops
# an installation-directory one there before this layout exists. A stray whose
# name this provider owns is deleted -- the rebuild has already placed the real
# one -- and everything else lands in Vendor.
${sweepRoots} = @(${desktop})
${mastUserDesktop} = 'C:\Users\mast\Desktop'
if ((Test-Path -LiteralPath ${mastUserDesktop}) -and (${mastUserDesktop} -ne ${desktop})) {
    ${sweepRoots} += ${mastUserDesktop}
}
# A tool this provider now creates in a class folder must not also sit in
# Vendor, where an installer's own copy has been kept since before the
# promotion. Only these are removed; every other stray stays, because nothing
# would ever put it back.
foreach (${item} in @(Get-ChildItem -LiteralPath ${dirVendor} -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.lnk', '.url') })) {
    if (${ownedNames} -contains ${item}.Name) {
        Remove-Item -LiteralPath ${item}.FullName -Force
        Write-ShortcutLog ("Removed the installer's copy of a promoted tool from Vendor: {0}" -f ${item}.Name)
    }
}

# The bootstrap report is written once, by a first-touch bootstrap run, for the
# operator standing at a bare machine: MACs for the DHCP reservations, the BIOS
# power checklist, the handoff steps. All of it is spent by the time the unit
# provisions, and nothing regenerates it -- a re-assert run returns before the
# writer -- so what survives on a provisioned desktop is a snapshot of a machine
# state months gone. Removed rather than kept: the bootstrap log it was rendered
# from stays at C:\MAST\logs\bootstrap.log.
foreach (${root} in ${sweepRoots}) {
    ${report} = Join-Path ${root} 'MAST Bootstrap Report.txt'
    if (Test-Path -LiteralPath ${report}) {
        Remove-Item -LiteralPath ${report} -Force
        Write-ShortcutLog ("Removed the spent bootstrap report: {0}" -f ${report})
    }
}

foreach (${root} in ${sweepRoots}) {
    foreach (${item} in @(Get-ChildItem -LiteralPath ${root} -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.lnk', '.url') })) {
        if (${ownedNames} -contains ${item}.Name) {
            Remove-Item -LiteralPath ${item}.FullName -Force
            Write-ShortcutLog ("Removed loose copy of a shortcut this layout owns: {0} (from {1})" -f ${item}.Name, ${root})
            continue
        }
        Move-Item -LiteralPath ${item}.FullName -Destination (Join-Path ${dirVendor} ${item}.Name) -Force
        Write-ShortcutLog ("Swept loose shortcut into Vendor: {0} (from {1})" -f ${item}.Name, ${root})
    }
}

Write-ShortcutLog 'Desktop shortcuts provisioning complete.'
exit 0
