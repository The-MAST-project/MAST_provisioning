#requires -Version 5.1
[CmdletBinding()]
param()

# Verify PHDLogView installed. On failure, dump diagnostic info so we don't
# have to WinRM back in: typical cause is the InnoSetup installer needing
# something not available under WinRM (registry HKCU access, elevation).

$ErrorActionPreference = 'Stop'
$logRoot   = Join-Path (Join-Path $env:SystemDrive 'MAST') 'logs'
$verifyLog = Join-Path $logRoot 'verify\phd2-log-viewer-verify.log'
$smokeFile = Join-Path $logRoot 'smoke\phd2-log-viewer-smoke.txt'
$null = New-Item -ItemType Directory -Force -Path (Split-Path $verifyLog -Parent), (Split-Path $smokeFile -Parent) -ErrorAction SilentlyContinue

function W { param([string]$Line) Add-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Line) }
Set-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] verify-phd2-log-viewer.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$candidates = @(
    (Join-Path $env:ProgramFiles 'PHDLogView\phdlogview.exe'),
    (Join-Path $env:ProgramFiles 'PHD2 Log Viewer\phdlogview.exe'),
    (Join-Path $env:ProgramFiles 'PHD2 Log Viewer\PHD2 Log Viewer.exe'),
    'C:\Program Files\PHDLogView\phdlogview.exe',
    'C:\Program Files\PHD2 Log Viewer\phdlogview.exe',
    'C:\Program Files\PHD2 Log Viewer\PHD2 Log Viewer.exe',
    'C:\Program Files (x86)\PHDLogView\phdlogview.exe',
    'C:\Program Files (x86)\PHD2 Log Viewer\phdlogview.exe',
    'C:\Program Files (x86)\PHD2 Log Viewer\PHD2 Log Viewer.exe'
)
$exe = $null
foreach ($p in $candidates) {
    if (Test-Path -LiteralPath $p) { $exe = $p; break }
}
# Fallback: recursive search (matches the provider's strategy).
if (-not $exe) {
    foreach ($root in @('C:\Program Files', 'C:\Program Files (x86)')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $hit = Get-ChildItem -LiteralPath $root -Recurse -File `
                   -Include 'phdlogview.exe','PHD2 Log Viewer.exe' `
                   -ErrorAction SilentlyContinue -Depth 3 | Select-Object -First 1
        if ($hit) { $exe = $hit.FullName; break }
    }
}

if ($exe) {
    W ("PASS phdlogview at {0}" -f $exe)
    Set-Content -Path $smokeFile -Encoding ASCII -Value 'phd2_log_viewer_ok'
    exit 0
}

# ---- failure path: dump diagnostics ----
W "FAIL phdlogview.exe not found in any expected location"

W "--- elevation status of verify process ---"
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
W ("user={0}  isAdmin={1}  authType={2}" -f $identity.Name,
    $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator),
    $identity.AuthenticationType)

W "--- checked candidate paths ---"
foreach ($p in $candidates) { W ("  {0}  exists={1}" -f $p, (Test-Path -LiteralPath $p)) }

W "--- contents of likely install parent dirs ---"
foreach ($parent in @($env:ProgramFiles, 'C:\Program Files', 'C:\Program Files (x86)')) {
    if (-not (Test-Path -LiteralPath $parent)) { continue }
    Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*PHD*' -or $_.Name -like '*phdlog*' } |
        ForEach-Object { W ("  {0} -> last write {1}" -f $_.FullName, $_.LastWriteTime) }
}

W "--- InnoSetup install log tail (if InnoSetup wrote one) ---"
# InnoSetup writes its log to %TEMP%\Setup Log YYYY-MM-DD #001.txt by default,
# but only when /LOG is passed. Check anyway.
$tempLogs = @(Get-ChildItem $env:TEMP -Filter 'Setup Log*.txt' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1)
if ($tempLogs.Count -gt 0) {
    W ("  log: {0}" -f $tempLogs[0].FullName)
    Get-Content -LiteralPath $tempLogs[0].FullName -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { W ("    {0}" -f $_) }
} else {
    W "  (no InnoSetup log under TEMP)"
}

W "--- registry uninstall entries matching 'phdlogview' or 'PHD Log' ---"
foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
                    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
        if ($props.DisplayName -match 'PHD ?Log|phdlogview') {
            W ("  {0}  DisplayName={1}  InstallLocation={2}" -f $root, $props.DisplayName, $props.InstallLocation)
        }
    }
}

exit 1
