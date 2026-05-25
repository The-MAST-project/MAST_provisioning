#requires -Version 5.1
[CmdletBinding()]
param()

# Verify USBPcap installed AND its kernel driver service registered.
# On failure, dump diagnostics inline so we don't have to WinRM back in to
# figure out why -- typical cause is the WinRM network-logon token having
# BUILTIN\Administrators filtered out, which silently blocks kernel driver
# registration even though the user is nominally an admin.

$ErrorActionPreference = 'Stop'
$logRoot   = Join-Path (Join-Path $env:SystemDrive 'MAST') 'logs'
$verifyLog = Join-Path $logRoot 'verify\usbpcap-verify.log'
$smokeFile = Join-Path $logRoot 'smoke\usbpcap-smoke.txt'
$null = New-Item -ItemType Directory -Force -Path (Split-Path $verifyLog -Parent), (Split-Path $smokeFile -Parent) -ErrorAction SilentlyContinue

function W { param([string]$Line) Add-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Line) }
Set-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] verify-usbpcap.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$candidates = @(
    (Join-Path $env:ProgramFiles 'USBPcap\USBPcapCMD.exe'),
    'C:\Program Files\USBPcap\USBPcapCMD.exe',
    'C:\Program Files (x86)\USBPcap\USBPcapCMD.exe'
)
$exe = $null
foreach ($p in $candidates) {
    if (Test-Path -LiteralPath $p) { $exe = $p; break }
}
$svc = Get-Service -Name 'USBPcap' -ErrorAction SilentlyContinue

if ($exe -and $svc) {
    W ("PASS USBPcapCMD={0} svc Status={1} StartType={2}" -f $exe, $svc.Status, $svc.StartType)
    Set-Content -Path $smokeFile -Encoding ASCII -Value 'usbpcap_ok'
    exit 0
}

# ---- failure path: dump diagnostics ----
W ("FAIL exe={0} svc={1}" -f ($exe -ne $null), ($svc -ne $null))

W "--- elevation status of verify process ---"
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
W ("user={0}  isAdmin={1}  authType={2}" -f $identity.Name,
    $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator),
    $identity.AuthenticationType)

W "--- USBPcap install dir contents ---"
foreach ($d in @('C:\Program Files\USBPcap','C:\Program Files (x86)\USBPcap')) {
    if (Test-Path -LiteralPath $d) {
        W ("  {0}:" -f $d)
        Get-ChildItem -LiteralPath $d -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 20 | ForEach-Object { W ("    {0,12} {1}" -f $_.Length, $_.FullName) }
    } else {
        W ("  ({0} missing)" -f $d)
    }
}

W "--- driver service registry entry ---"
$svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\USBPcap'
if (Test-Path -LiteralPath $svcKey) {
    Get-ItemProperty -LiteralPath $svcKey | Select-Object Type, Start, ImagePath, DisplayName |
        Format-List | Out-String | ForEach-Object { foreach ($ln in ($_ -split "`r?`n")) { if ($ln.Trim()) { W ("  {0}" -f $ln.Trim()) } } }
} else {
    W ("  ({0} missing -- driver was never registered)" -f $svcKey)
}

W "--- recent SetupAPI driver errors (last 30 min) ---"
try {
    Get-WinEvent -FilterHashtable @{ LogName='Setup'; StartTime=(Get-Date).AddMinutes(-30) } -MaxEvents 20 -ErrorAction Stop |
        Where-Object { $_.LevelDisplayName -in @('Error','Warning') -and $_.Message -match 'usbpcap|USB|driver' } |
        Select-Object -First 5 | ForEach-Object {
            W ("  {0} {1} {2}" -f $_.TimeCreated.ToString('HH:mm:ss'), $_.LevelDisplayName, (($_.Message -split "`r?`n")[0]))
        }
} catch {
    W ("  (could not read Setup event log: {0})" -f $_.Exception.Message)
}

exit 1
