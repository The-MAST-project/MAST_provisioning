#requires -Version 5.1
[CmdletBinding()]
param(
    # Dev-VM-only escape: provide-usbpcap.ps1 itself prints
    # "[WARN] USBPcap service not registered; capture will not work until a
    # reboot or manual sc create." -- the installer runs cleanly but the kernel
    # driver service entry only becomes queryable after the post-install reboot.
    # Our provisioning pipeline is reboot-free (the `reboot` module at order
    # 9999 only emits a flag), so on a VM run -- where iteration speed depends
    # on staying inside one WinRM session and snapshot-restore is the reset
    # model -- the service registration cannot complete inside the cycle.
    # build-mast.ps1 injects -AllowPendingReboot only under -TestMode; prod
    # MUST NOT pass it. With the flag, the "exe present + service absent"
    # state is treated as SKIPPED (smoke `usbpcap_skipped reason=pending_reboot`)
    # instead of FAIL. exe-absent stays a hard FAIL regardless -- that
    # indicates the installer itself didn't run.
    [switch]${AllowPendingReboot}
)

# Verify USBPcap installed AND its kernel driver service registered.
# On failure, dump diagnostics inline so we don't have to WinRM back in to
# figure out why -- typical cause is the WinRM network-logon token having
# BUILTIN\Administrators filtered out, which silently blocks kernel driver
# registration even though the user is nominally an admin.

$ErrorActionPreference = 'Stop'
$mastLogDot = Join-Path $PSScriptRoot 'mast-log.ps1'
if (-not (Test-Path $mastLogDot)) { $mastLogDot = Join-Path $PSScriptRoot '..\..\lib\mast-log.ps1' }
. $mastLogDot
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; verify scripts predate it and probe optional properties
$verifyLog = Get-MastVerifyLog -Module 'usbpcap'

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
    Write-MastSmokeOk -Module 'usbpcap' | Out-Null
    exit 0
}

# Dev-VM escape: exe is present but the kernel driver service entry won't
# appear until after a reboot. With -AllowPendingReboot we treat this as a
# SKIP -- the installer demonstrably ran (binary on disk) and service
# registration is deferred to a reboot we are not going to perform inside
# this WinRM run. exe-absent stays a hard FAIL: that means the installer
# itself failed and there is no way a reboot would resolve it.
if ($AllowPendingReboot -and $exe -and -not $svc) {
    W ("SKIP USBPcapCMD={0} but svc 'USBPcap' not registered -- pending reboot. -AllowPendingReboot set; treating as skipped." -f $exe)
    Write-MastSmokeOk -Module 'usbpcap' -Value 'usbpcap_skipped reason=pending_reboot' | Out-Null
    exit 0
}

# ---- failure path: dump diagnostics ----
W ("FAIL exe={0} svc={1} AllowPendingReboot={2}" -f ($exe -ne $null), ($svc -ne $null), [bool]$AllowPendingReboot)

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
