#Requires -RunAsAdministrator
<#
.SYNOPSIS
    One-time bootstrap for a freshly installed MAST IoT unit (physical or VM).

.DESCRIPTION
    Run this script ONCE on a unit that has a clean Windows IoT install with no
    answer file. It brings the machine to a state where prepare-mast-client.ps1
    can run remotely over WinRM to finish the full unit preparation.

    What this script does:
      1. If an OEM factory account exists (default 'user' from unattend), renames it
         to mast and sets the provisioning password.
      2. Ensures the 'mast' local administrator account (password: physics).
      3. Suppresses Windows Update automatic installs and reboots.
      4. Enables WinRM over HTTP (port 5985) with Basic auth.
      5. Opens the WinRM firewall port.

    Networking is DHCP - no static IP. Operators reach units by hostname (DNS / hosts).

    prepare-mast-client.ps1 (run remotely after this) handles:
      - Computer rename
      - WinRM HTTPS listener + self-signed cert
      - TrustedHosts configuration

    Delivery:
      - USB drive: copy to USB, open admin PowerShell on the unit, run it
      - Local keyboard / paste into an admin PowerShell session

    For VM builds using run-prov-test.py --build-image, equivalent commands are
    injected automatically into the answer file's FirstLogonCommands -- no manual
    step required.
#>

param(
    # Local name created by factory unattend (user/password1). Renamed to MastUser before WinRM. Use '' to skip.
    [string]$FactoryUser   = 'user',
    [string]$MastUser      = 'mast',
    [string]$MastPassword  = 'physics',
    [string]$ProvServerIP  = '192.168.56.1'
)

$ErrorActionPreference = 'Stop'

$totalSw = [System.Diagnostics.Stopwatch]::StartNew()
$phaseSw = [System.Diagnostics.Stopwatch]::StartNew()
function Format-MastElapsed([TimeSpan]$t) {
    if ($t.TotalHours -ge 1) { return $t.ToString('h\:mm\:ss') }
    if ($t.TotalMinutes -ge 1) { return ('{0:N1} min' -f $t.TotalMinutes) }
    return ('{0:N2}s' -f $t.TotalSeconds)
}
function Write-MastTiming([string]$Label) {
    $phaseSw.Stop()
    Write-Host ('[TIMING] {0}: {1}' -f $Label, (Format-MastElapsed $phaseSw.Elapsed)) -ForegroundColor DarkCyan
    $phaseSw.Restart()
}
function Write-MastTimingTotal([string]$ScriptName) {
    $totalSw.Stop()
    Write-Host ('[TIMING] Total ({0}): {1}' -f $ScriptName, (Format-MastElapsed $totalSw.Elapsed)) -ForegroundColor Cyan
}

function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "--- $msg" -ForegroundColor Cyan
}

$phaseSw.Restart()

# ---------------------------------------------------------------------------
# OEM factory account -> mast (optional)
# Unattend installs use generic credentials (e.g. user/password1); rename here so one
# script is sufficient before provisioning. Skip when FactoryUser is empty or absent.
# ---------------------------------------------------------------------------
$RenamedOemToMast = $false
if ($FactoryUser) {
    Write-Step "OEM factory account -> '$MastUser'"
    $factoryAcct = Get-LocalUser -Name $FactoryUser -ErrorAction SilentlyContinue
    $mastAcct    = Get-LocalUser -Name $MastUser -ErrorAction SilentlyContinue
    if ($factoryAcct -and $mastAcct) {
        throw "Bootstrap: cannot rename '$FactoryUser' to '$MastUser' because '$MastUser' already exists."
    }
    if ($factoryAcct -and -not $mastAcct) {
        $secPwd = ConvertTo-SecureString $MastPassword -AsPlainText -Force
        Rename-LocalUser -Name $FactoryUser -NewName $MastUser
        Set-LocalUser -Name $MastUser -Password $secPwd -PasswordNeverExpires $true
        $RenamedOemToMast = $true
        Write-Host "  Renamed '$FactoryUser' -> '$MastUser'; password set for provisioning."
    } else {
        Write-Host "  No factory account '$FactoryUser' (or mast already present) -- skipping rename."
    }
}
Write-MastTiming 'OEM account rename'

# ---------------------------------------------------------------------------
# 1. mast local administrator account (creates or syncs password after OEM rename)
# ---------------------------------------------------------------------------
Write-Step "Ensuring local admin account '$MastUser'"

$existing = Get-LocalUser -Name $MastUser -ErrorAction SilentlyContinue
$secPwd = ConvertTo-SecureString $MastPassword -AsPlainText -Force

if ($existing) {
    Set-LocalUser -Name $MastUser -Password $secPwd -PasswordNeverExpires $true
    if ($RenamedOemToMast) {
        Write-Host "  Password synced for '$MastUser' (same account as renamed OEM user -- expected)."
    } else {
        Write-Host "  Account '$MastUser' already exists -- password updated."
    }
} else {
    New-LocalUser -Name $MastUser -Password $secPwd `
        -FullName 'MAST Administrator' -PasswordNeverExpires `
        -UserMayNotChangePassword | Out-Null
    Write-Host "  Account '$MastUser' created."
}

# Add to Administrators if not already a member (rename leaves OEM admin in Administrators).
# Match by SID first; Name formats vary. Add-LocalGroupMember is wrapped: MemberExists must not abort ($ErrorActionPreference = Stop).
$mastSid = (Get-LocalUser -Name $MastUser).Sid
$alreadyAdmin = $false
foreach ($m in @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue)) {
    if ($m.SID -eq $mastSid) {
        $alreadyAdmin = $true
        break
    }
}
if (-not $alreadyAdmin) {
    try {
        Add-LocalGroupMember -Group 'Administrators' -Member $MastUser -ErrorAction Stop
        Write-Host "  Added '$MastUser' to Administrators."
    } catch {
        $fe = $_.FullyQualifiedErrorId
        if ($fe -match 'MemberExists|ResourceExists') {
            Write-Host "  '$MastUser' is already an Administrator."
        } else {
            throw
        }
    }
} else {
    Write-Host "  '$MastUser' is already an Administrator."
}
Write-MastTiming 'mast account + Administrators'

# ---------------------------------------------------------------------------
# 2. Suppress Windows Update automatic installs
# ---------------------------------------------------------------------------
Write-Step "Suppressing Windows Update automatic installs"

$auPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $auPath -Force | Out-Null
# AUOptions = 1: never check (fully suppressed during provisioning)
Set-ItemProperty -Path $auPath -Name NoAutoUpdate  -Value 1 -Type DWord
Set-ItemProperty -Path $auPath -Name AUOptions     -Value 1 -Type DWord
# Prevent automatic reboots even if updates somehow slip through
Set-ItemProperty -Path $auPath -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord

Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Set-Service  wuauserv -StartupType Disabled
Write-Host "  Windows Update disabled (AUOptions=1, service=Disabled)."
Write-MastTiming 'Windows Update policy'

# ---------------------------------------------------------------------------
# 3. Enable WinRM (HTTP, Basic auth, unencrypted)
# ---------------------------------------------------------------------------
Write-Step "Enabling WinRM"

# Prefer Private profiles for WS-Man policies. At first logon after OEM rename,
# NetTCPIP cmdlets (Get-NetConnectionProfile, Get-NetAdapter, etc.) use CIM and can
# throw 0x80070534 ("No mapping between account names and security IDs") until the
# session/profile mapping settles -- same HRESULT as the earlier warning. Do not
# abort bootstrap; registry fallback + Enable-PSRemoting -SkipNetworkProfileCheck still run.
Write-Host "  Setting NetConnectionProfiles to Private (best-effort)"
try {
    $profiles = @(Get-NetConnectionProfile -ErrorAction Stop)
    foreach ($p in $profiles) {
        try {
            Set-NetConnectionProfile -InputObject $p -NetworkCategory Private -ErrorAction Stop
        } catch {
            Write-Host ("  WARN: could not set profile '{0}' to Private: {1}" -f $p.Name, $_.Exception.Message)
        }
    }
} catch {
    Write-Host ("  WARN: Get-NetConnectionProfile failed (continuing): {0}" -f $_.Exception.Message)
}

# Per-adapter step can fail entirely when Get-NetAdapter hits the same CIM 0x80070534;
# catch so we still reach registry fallback and WinRM enablement.
try {
    foreach ($a in @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
        try {
            $p = Get-NetConnectionProfile -InterfaceIndex $a.ifIndex -ErrorAction Stop
            Set-NetConnectionProfile -InputObject $p -NetworkCategory Private -ErrorAction Stop
            Write-Host ("  Set profile Private via adapter '{0}'." -f $a.Name)
        } catch {
            # ignore per-adapter failures
        }
    }
} catch {
    Write-Host ("  WARN: Get-NetAdapter / per-adapter NetConnectionProfile skipped: {0}" -f $_.Exception.Message)
}
$nlProfiles = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles'
if (Test-Path $nlProfiles) {
    Get-ChildItem $nlProfiles -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Set-ItemProperty -LiteralPath $_.PSPath -Name 'Category' -Value 1 -Type DWord -Force -ErrorAction Stop
        } catch {}
    }
    Write-Host "  Applied registry fallback: NetworkList Profiles Category=Private where possible."
}
try {
    Restart-Service nlasvc -Force -ErrorAction Stop
    Start-Sleep -Seconds 3
} catch {}

# Enable-PSRemoting starts the WinRM service and creates a default HTTP listener
Enable-PSRemoting -Force -SkipNetworkProfileCheck

# NOTE: 'winrm set ... @{Key="val"}' is unreliable from PowerShell because
# PS parses @{...} as a hashtable literal; use the WSMan: provider instead.
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true -Force            # Basic auth for pywinrm / run-prov-test.py
try {
    Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true -Force      # bootstrap only; prepare-mast-client.ps1 adds HTTPS
} catch {
    Write-Host ("  WARN: AllowUnencrypted not set yet ({0}); retrying after another NLA refresh..." -f $_.Exception.Message)
    try { Restart-Service nlasvc -Force; Start-Sleep -Seconds 4 } catch {}
    try {
        Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true -Force
    } catch {
        Write-Host ("  WARN: AllowUnencrypted still not set: {0}. Fix network location (Private/Domain) or reboot; pywinrm may need HTTPS." -f $_.Exception.Message)
    }
}

Set-Service WinRM -StartupType Automatic
Write-Host "  WinRM enabled (HTTP, Basic auth). Check warnings above for AllowUnencrypted."
Write-MastTiming 'WinRM HTTP + Basic'

# ---------------------------------------------------------------------------
# 3b. Allow remote admin auth via local accounts (UAC token-filter bypass)
#     Without this, WinRM Basic auth with a local admin (other than the
#     built-in 'Administrator') returns 401 even when the password is right.
# ---------------------------------------------------------------------------
Write-Step "Setting LocalAccountTokenFilterPolicy=1"
$polPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
New-ItemProperty -Path $polPath -Name LocalAccountTokenFilterPolicy `
    -Value 1 -PropertyType DWord -Force | Out-Null
Restart-Service WinRM
Write-Host "  LocalAccountTokenFilterPolicy=1; WinRM restarted."
Write-MastTiming 'LocalAccountTokenFilterPolicy'

# ---------------------------------------------------------------------------
# 4. Firewall -- open WinRM HTTP port
# ---------------------------------------------------------------------------
Write-Step "Opening WinRM firewall port 5985"

$ruleName = 'MAST - WinRM HTTP'
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName `
        -Direction Inbound -Protocol TCP -LocalPort 5985 `
        -Action Allow -Profile Any | Out-Null
    Write-Host "  Firewall rule '$ruleName' created."
} else {
    Write-Host "  Firewall rule '$ruleName' already exists."
}
Write-MastTiming 'Firewall rule 5985'

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
$addrs = @(Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
    ForEach-Object { $_.IPAddress })

Write-Host ""
Write-Host "Bootstrap complete." -ForegroundColor Green
Write-Host ""
Write-Host ("  IPv4 address(es): {0}" -f (($addrs | Sort-Object -Unique) -join ', '))
Write-Host "  WinRM port       : 5985 (HTTP)"
Write-Host "  Account          : $MastUser / $MastPassword"
Write-Host ""
Write-Host "Next: ensure DNS (or hosts on the prov server) resolves the unit by hostname."
Write-Host "Then from the prov server run prepare-mast-client.ps1 (example for mast01):"
Write-Host '    $cred = Get-Credential   # mast / physics'
Write-Host "    Invoke-Command -ComputerName mast01 -Credential `$cred ``"
Write-Host "        -FilePath .\client\prepare-mast-client.ps1 ``"
Write-Host "        -ArgumentList @{ HostName = 'mast01'; Provider = '$ProvServerIP' }"
Write-MastTimingTotal 'bootstrap-winrm.ps1'
