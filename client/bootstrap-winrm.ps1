#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Manual first-time MAST unit bootstrap: mast admin, auto-logon, WinRM HTTP for prov server, optional computer rename.

.DESCRIPTION
    Run ONCE per machine in an elevated PowerShell session after Windows is installed (physical unit
    from USB, or dev VM after first login). This is NOT run from autounattend FirstLogon anymore.

    The installing operator must supply the unit Windows hostname (e.g. mast05). The script:
      1. Leaves the OEM factory local account (default 'user') intact; creates a separate 'mast' account.
      2. Ensures 'mast' is a local administrator with the provisioning password.
      3. Configures auto-logon for 'mast' (Winlogon AutoAdminLogon) so a headless unit
         signs in unattended after every reboot and the interactive control stack comes
         back up without an operator at the console. Skippable via -SkipAutoLogon.
      4. Suppresses Windows Update automatic installs.
      5. Ensures IPv4 uses DHCP. The fleet identifies units by hostname and requires
         DHCP addressing; if an adapter was hand-set to a static IP it is switched
         back to DHCP (IP + DNS). Adapters already on DHCP are left untouched.
      6. Enables WinRM over HTTP (5985) with Basic auth and opens firewall port 5985.
      7. Installs the Npcap packet-capture driver via its interactive GUI (the free edition
         has no working silent mode; operator clicks through once). The npcap installer
         (npcap-*.exe) must sit next to this script or under .\assets.
      8. Renames the computer to -MastHostName (reboot required before the new name is live).
      9. Hardens telemetry/privacy: diagnostic data = Security (lowest), disables the
         DiagTrack + dmwappushservice diagnostic-upload services, advertising ID,
         activity feed, Cortana / web search, app background+location, etc.
     10. Sets the regional format to English (United States) (locale en-US): the
         system locale, home location, and the per-user 'Control Panel\International'
         values (date/time/number/currency formatting) for the mast account, the
         Default-user profile template, the .DEFAULT hive, and the current user.
     11. Disables the Windows Firewall on all profiles. MAST units sit on an isolated
         VLAN behind a perimeter firewall and need open intra-fleet traffic
         (COM/RPC, Prometheus scraping, the control stack).
     12. Stops + disables non-essential / vendor services that have no role on a
         headless control box (Print Spooler, Windows Search, Intel LMS, ASUS /
         Intel GCC / Realtek helpers). Applied by default; each is skippable via
         -SkipTrim. Remote-desktop and backup APPS are left to uninstall by hand -
         listed at the end of a run.

    This script performs ALL first-time prep; there is no separate prepare step. After it
    completes successfully, the operator verifies the summary and reboots if prompted. The unit
    is then ready for provisioning (the prov server's check-and-provision.ps1 loop picks it up
    once it is in unit-registry.json, or run client\onboard-mast-unit.ps1 on the unit).

    USB / DVD: copy client\bootstrap-winrm.cmd, bootstrap-winrm.ps1, and the Npcap installer
    (client\assets\npcap-*.exe) together (or use the autounattend ISO, which bundles all three).
    Double-click bootstrap-winrm.cmd so Windows runs PowerShell (many PCs
    open .ps1 in Notepad by default). Or from an elevated PowerShell:
        cd <folder containing bootstrap-winrm.ps1>
        .\bootstrap-winrm.ps1 -MastHostName mast05

    If you omit -MastHostName, the script prompts interactively (not valid with -NonInteractive).

.PARAMETER MastHostName
    Windows computer name for this unit (mast01 .. mast20). NetBIOS: 1-15 chars, letters/digits/hyphen.

.PARAMETER Site
    Site code (e.g. 'ns', 'wis') selecting the unit's configuration profile at provisioning
    time. The operator's explicit choice -- NEVER derived from the hostname; persisted to
    C:\ProgramData\MAST\site.txt for onboard-mast-unit.ps1 to record in the prov server's
    unit-registry.json. Prompted interactively (default 'ns') if omitted; required with
    -NonInteractive.

.PARAMETER NonInteractive
    Fail if -MastHostName is missing (for automation); no prompts.

.PARAMETER RebootAfterBootstrap
    After success, schedule a reboot in 90 seconds (recommended after Rename-Computer or if WinRM/CIM was flaky).

.PARAMETER SkipComputerRename
    Do not rename the computer (use only if you will set the name elsewhere).

.PARAMETER SkipAutoLogon
    Do not configure Winlogon auto-logon for the mast account. By default the unit is set
    to sign 'mast' in automatically at every boot (headless control box); pass this to leave
    the machine at the interactive sign-in screen instead.

.PARAMETER FactoryUser
    DEPRECATED no-op. Previously named the OEM account to rename to 'mast'; the rename
    behavior has been removed (it stranded %USERPROFILE% at C:\Users\user). The OEM
    account is now left intact and a fresh 'mast' account is created instead. The
    parameter is still accepted so existing autounattend invocations keep working.

.PARAMETER MastUser, MastPassword, ProvServerIP
    Same defaults as factory unattend ('mast' / 'physics' / prov host for prepare example text).

.PARAMETER VmTestRun
    *** VM TESTING ONLY - DO NOT USE IN PRODUCTION ***
    Adds a hosts file entry mapping mast-wis-control -> 192.168.56.1 (the VirtualBox host-only
    host IP) so the MongoDB client inside the VM connects to the host machine's MongoDB instance.
    The entry is marked with # MAST-VM-TEST-ONLY for easy identification and removal.

.PARAMETER SkipTrim
    Service short-names to leave alone when the non-essential / vendor service trim
    runs (Print Spooler, Windows Search, Intel LMS, ASUS / Intel GCC / Realtek
    helpers), e.g. -SkipTrim WSearch,Spooler. The trim is applied by default;
    -SkipTrim is the only way to exempt specific services. Service names vary by
    driver version, so each entry carries a display-name fallback; anything not
    found is just reported "not present". Idempotent; safe to re-run.
#>

param(
    [string]$FactoryUser = 'user',
    [string]$MastUser = 'mast',
    [string]$MastPassword = 'physics',
    [string]$ProvServerIP = '192.168.56.1',
    [string]$MastHostName = '',
    [string]$Site = '',
    [switch]$NonInteractive,
    [switch]$RebootAfterBootstrap,
    [switch]$SkipComputerRename,
    [switch]$VmTestRun,
    [switch]$SkipAutoLogon,
    [string[]]$SkipTrim = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$_clientUtilDot = Join-Path $PSScriptRoot 'mast-client-util.ps1'
if (Test-Path $_clientUtilDot) { . $_clientUtilDot }

$script:BootstrapLogDir = Join-Path $env:SystemDrive 'MAST\logs'
$script:BootstrapLog = Join-Path $script:BootstrapLogDir 'bootstrap-winrm.log'
$script:RebootRecommended = $false
$script:AllowUnencryptedOk = $false

# Bootstrap version: stamped to C:\MAST\bootstrap-manifest.json on success so the fleet
# drift report (tools/fleet-drift-report.py) can tell which bootstrap each unit ran and
# flag units missing newer bootstrap elements. BUMP THIS whenever you add a bootstrap
# capability, and add a matching element (since = this number) to
# client/bootstrap-elements.json so its current_version stays == this value.
$script:BootstrapVersion = 1

# --- Service trim list (applied by default; exempt with -SkipTrim) ------------
# Non-essential / vendor services with no role on a headless control box. Service
# names vary by driver version, so each row carries a display-name fallback (Match);
# anything not found is reported "not present". The DiagTrack + dmwappushservice
# diagnostic-upload services are NOT here -- they are disabled separately in the
# telemetry section and are never exempted by -SkipTrim.
$script:TrimList = @(
    @{ Name = 'Spooler';                  Match = '*Print Spooler*';            Desc = 'Print Spooler - no printing; PrintNightmare surface' }
    @{ Name = 'WSearch';                  Match = '*Windows Search*';           Desc = 'Windows Search indexing - I/O overhead' }
    @{ Name = 'LMS';                      Match = '*Local Management Service*'; Desc = 'Intel Local Management Service (AMT/ME)' }
    @{ Name = 'AsusCertService';          Match = '*Asus*Cert*';                Desc = 'ASUS Certificate Service (vendor utility)' }
    @{ Name = 'IGCCService';              Match = '*Graphics Command Center*';  Desc = 'Intel Graphics Command Center service' }
    @{ Name = 'RtkAudioUniversalService'; Match = '*Realtek*Audio*';            Desc = 'Realtek audio service (no audio use)' }
    @{ Name = 'jhi_service';              Match = '*DAL*Host Interface*';       Desc = 'Intel DAL Host Interface (ME)' }
    @{ Name = 'WMIRegistrationService';   Match = '*WMI*Registration*';         Desc = 'Intel ME WMI registration (vendor)' }
)

# Apps to remove by hand (Settings > Apps) - not services, so not scripted. Printed
# as a reminder at the end of every run.
$script:AppsToUninstall = @(
    'AnyDesk                       - third-party remote desktop (cloud relay); keep NoMachine + SSH instead'
    'VNC server (RealVNC/TightVNC) - redundant remote desktop (vncserver / vncagent)'
    'Macrium Reflect               - ONLY if this unit is not using it for imaging/backup'
    'ASUS Armoury Crate / AI Suite - optional; the AsusCertService is disabled by the service trim'
    'Intel Graphics Command Center - optional; the IGCC service is disabled by the service trim'
)

$null = New-Item -ItemType Directory -Path $script:BootstrapLogDir -Force -ErrorAction SilentlyContinue

function Write-BootstrapMsg {
    param(
        [string]$Message,
        [string]$Color = 'Gray'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Message"
    Add-Content -LiteralPath $script:BootstrapLog -Encoding ASCII -Value $line
    Write-Host $Message -ForegroundColor $Color
}

function Write-BootstrapBanner([string]$Text, [string]$Color = 'Cyan') {
    Write-BootstrapMsg $Text $Color
}

function Test-MastNetFirewallRuleExists {
    param([string]$DisplayName)
    try {
        return [bool](Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}

function Resolve-MastTrimService {
    # Find a trim entry's service by exact short-name, else by display-name pattern.
    param($Entry)
    $s = Get-Service -Name $Entry.Name -ErrorAction SilentlyContinue
    if (-not $s -and $Entry.Match) {
        $s = Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $Entry.Match } | Select-Object -First 1
    }
    $s
}

function Set-MastAdaptersToDhcp {
    # Safeguard: the MAST fleet identifies units by hostname and REQUIRES DHCP for
    # IPv4 (autonomous-provisioning-requirements.md "Identity and addressing"). If a
    # unit was hand-set to a static address, switch its physical adapters back to
    # DHCP (IP + DNS). Only adapters currently on static IPv4 are touched, so a unit
    # already on DHCP is left undisturbed (no lease churn, no link blip). Idempotent.
    $adapters = @()
    try {
        $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    } catch {
        Write-BootstrapMsg ("  WARN: Get-NetAdapter failed: {0}" -f $_.Exception.Message) 'Yellow'
        return
    }
    if (-not $adapters) {
        Write-BootstrapMsg '  No physical adapters are Up; nothing to check.' 'DarkGray'
        return
    }
    $changed = 0
    foreach ($a in $adapters) {
        $iface = $null
        try {
            $iface = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction Stop
        } catch {
            Write-BootstrapMsg ("  WARN: cannot read IPv4 interface for '{0}': {1}" -f $a.Name, $_.Exception.Message) 'Yellow'
            continue
        }
        if ($iface.Dhcp -eq 'Enabled') {
            Write-BootstrapMsg ("  '{0}' already uses DHCP for IPv4; leaving as-is." -f $a.Name) 'DarkGray'
            continue
        }
        Write-BootstrapMsg ("  '{0}' is on a static IPv4 config; switching to DHCP (IP + DNS)..." -f $a.Name) 'White'
        # netsh 'source=dhcp' switches address+gateway to DHCP and clears the static
        # entry in one step; Set-NetIPInterface -Dhcp Enabled alone can leave a stale
        # static IP behind. netsh takes the adapter alias (may contain spaces).
        $alias = $a.Name
        $null = cmd.exe /c ('netsh interface ip set address name="{0}" source=dhcp' -f $alias) 2>&1
        $ipRc = $LASTEXITCODE
        $null = cmd.exe /c ('netsh interface ip set dns name="{0}" source=dhcp register=primary' -f $alias) 2>&1
        $dnsRc = $LASTEXITCODE
        if ($ipRc -eq 0 -and $dnsRc -eq 0) {
            Write-BootstrapMsg ("  '{0}' switched to DHCP (IPv4 + DNS)." -f $alias) 'Green'
            $changed++
        } else {
            Write-BootstrapMsg ("  WARN: netsh DHCP switch for '{0}' returned ip={1} dns={2}; trying Set-NetIPInterface fallback." -f $alias, $ipRc, $dnsRc) 'Yellow'
            try {
                Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop
                Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop
                Write-BootstrapMsg ("  '{0}' switched to DHCP via Set-NetIPInterface fallback." -f $alias) 'Green'
                $changed++
            } catch {
                Write-BootstrapMsg ("  WARN: could not switch '{0}' to DHCP: {1}" -f $alias, $_.Exception.Message) 'Yellow'
            }
        }
    }
    if ($changed -gt 0) {
        # Acquire a fresh lease before WinRM / network-profile work runs.
        Write-BootstrapMsg ("  Renewing DHCP lease on {0} adapter(s)..." -f $changed) 'DarkGray'
        try { $null = cmd.exe /c 'ipconfig /renew' 2>&1 } catch { }
    }
}

function Ensure-MastWinRmFirewallRule5985 {
    param([string]$RuleDisplayName = 'MAST - WinRM HTTP')
    if (Test-MastNetFirewallRuleExists -DisplayName $RuleDisplayName) {
        Write-BootstrapMsg "  Firewall rule '$RuleDisplayName' already exists." 'Green'
        return
    }
    try {
        New-NetFirewallRule -DisplayName $RuleDisplayName `
            -Direction Inbound -Protocol TCP -LocalPort 5985 `
            -Action Allow -Profile Any -ErrorAction Stop | Out-Null
        Write-BootstrapMsg "  Firewall rule '$RuleDisplayName' created (NetSecurity module)." 'Green'
    } catch {
        Write-BootstrapMsg ("  WARN: New-NetFirewallRule failed ({0}); trying netsh advfirewall." -f $_.Exception.Message) 'Yellow'
        $showCmd = 'netsh advfirewall firewall show rule name="' + $RuleDisplayName.Replace('"', '') + '"'
        $show = cmd.exe /c $showCmd 2>&1
        $showText = if ($show) { ($show | Out-String) } else { '' }
        if ($LASTEXITCODE -eq 0 -and $showText -and $showText -notmatch 'No rules match') {
            Write-BootstrapMsg "  netsh: rule '$RuleDisplayName' already present." 'Green'
            return
        }
        $addCmd = 'netsh advfirewall firewall add rule name="' + $RuleDisplayName.Replace('"', '') + '" dir=in action=allow protocol=TCP localport=5985'
        $null = cmd.exe /c $addCmd 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Firewall: netsh advfirewall add rule failed (exit $LASTEXITCODE) after New-NetFirewallRule error."
        }
        Write-BootstrapMsg "  Firewall rule '$RuleDisplayName' created (netsh advfirewall)." 'Green'
    }
}

function Install-MastNetworkPrivateTask {
    # The provisioning link is typically a link-local-only NIC (169.254.x.x, no
    # gateway) which Windows classifies as an "Unidentified network" and forces
    # onto the Public profile. NLA re-evaluates this on EVERY boot, so the
    # one-shot "set Private" done above regresses to Public after the
    # provisioning reboot -- and Public breaks WinRM unencrypted-Basic (the prov
    # server gets HTTP 401, see DECISIONS). To make Private stick, drop a tiny
    # re-assert script and register a SYSTEM scheduled task that runs it at every
    # startup AND whenever a network profile changes.
    $scriptDir = Join-Path $env:SystemDrive 'MAST\scripts'
    $null = New-Item -ItemType Directory -Path $scriptDir -Force -ErrorAction SilentlyContinue
    $helper = Join-Path $scriptDir 'mast-set-network-private.ps1'
    $body = @'
# AUTO-GENERATED by bootstrap-winrm.ps1. Re-assert all network connection
# profiles to Private so the link-local provisioning NIC does not regress to
# Public (Public breaks WinRM unencrypted-Basic). Runs at boot + on net change.
$ErrorActionPreference = 'SilentlyContinue'
foreach ($p in @(Get-NetConnectionProfile)) {
    try { Set-NetConnectionProfile -InputObject $p -NetworkCategory Private } catch {}
}
$nl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles'
if (Test-Path $nl) {
    Get-ChildItem $nl -ErrorAction SilentlyContinue | ForEach-Object {
        try { Set-ItemProperty -LiteralPath $_.PSPath -Name 'Category' -Value 1 -Type DWord -Force } catch {}
    }
}
try { Restart-Service nlasvc -Force } catch {}
'@
    # LF-safe ASCII write (no BOM); content is plain ASCII so encoding is moot,
    # but matches the repo convention of WriteAllText for generated scripts.
    [System.IO.File]::WriteAllText($helper, $body, [System.Text.UTF8Encoding]::new($false))

    $taskName = 'MAST-NetworkPrivate'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $helper)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    $triggers = @()
    $startup = New-ScheduledTaskTrigger -AtStartup
    try { $startup.Delay = 'PT20S' } catch {}   # let NLA settle before re-asserting
    $triggers += $startup
    try {
        # Fire on NetworkProfile "connected" (Operational event 10000) so a
        # mid-session reclassification to Public is corrected within seconds.
        $cls = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' `
            -ClassName 'MSFT_TaskEventTrigger' -ErrorAction Stop
        $evt = New-CimInstance -CimClass $cls -ClientOnly
        $evt.Enabled = $true
        $evt.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10000)]]</Select></Query></QueryList>'
        $triggers += $evt
    } catch {
        Write-BootstrapMsg ("  WARN: network-change trigger unavailable ({0}); using startup trigger only." -f $_.Exception.Message) 'Yellow'
    }

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers `
        -Principal $principal -Force -ErrorAction Stop | Out-Null
    Write-BootstrapMsg "  Scheduled task '$taskName' registered (re-asserts Private at boot + on network change)." 'Green'

    # Run it once now so the current session is Private immediately.
    try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper } catch {}
}

function Show-BootstrapUserFixNetwork {
    Write-BootstrapMsg '' 'Yellow'
    Write-BootstrapMsg '--- USER ACTION: set network profile to Private ---' 'Yellow'
    Write-BootstrapMsg 'WinRM may refuse AllowUnencrypted while a profile is Public.' 'Yellow'
    Write-BootstrapMsg '  1) Open Settings > Network & internet > Ethernet (or Wi-Fi).' 'Yellow'
    Write-BootstrapMsg '  2) Open each active adapter > set Network profile type to Private.' 'Yellow'
    Write-BootstrapMsg '  3) Reboot, sign in as mast, then re-run this script (it is safe to re-run).' 'Yellow'
    Write-BootstrapMsg '  Or from elevated PowerShell (example):' 'Yellow'
    Write-BootstrapMsg '    Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private' 'Yellow'
}

function Show-BootstrapNextSteps([string]$HostNm) {
    Write-BootstrapMsg '' 'Yellow'
    Write-BootstrapMsg '--- MANUAL STEP: set ExecutionPolicy ---' 'Yellow'
    Write-BootstrapMsg '  Run this once in an elevated PowerShell on this machine:' 'Yellow'
    Write-BootstrapMsg '    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine' 'White'
    Write-BootstrapMsg '  Answer [Y] at the confirmation prompt.' 'Yellow'
    Write-BootstrapMsg '' 'Green'
    Write-BootstrapMsg '--- NEXT: hand off to provisioning ---' 'Green'
    Write-BootstrapMsg '  Bootstrap has done all first-time prep (mast admin, WinRM HTTP/5985, firewall,' 'Green'
    Write-BootstrapMsg '  OpenSSH, Npcap, Windows Update suppression, computer name). No prepare step remains.' 'Green'
    Write-BootstrapMsg "  1) Ensure the prov server resolves $HostNm (DNS or hosts entry)." 'Green'
    Write-BootstrapMsg "  2) Add $HostNm to server\unit-registry.json on the prov server; the autonomous" 'Green'
    Write-BootstrapMsg '     check-and-provision.ps1 loop will provision it on its next cycle.' 'Green'
    Write-BootstrapMsg '     Or, if client\onboard-mast-unit.ps1 was shipped to this unit, run it to' 'Green'
    Write-BootstrapMsg '     provision + register now (example):' 'Green'
    $obLine = '       .\onboard-mast-unit.ps1 -HostName ' + $HostNm + ' -ProvServer ' + $ProvServerIP
    Write-BootstrapMsg $obLine 'White'
    Write-BootstrapMsg '  Dev VM on VirtualBox host-only: run tools\sync-dev-unit-hosts.ps1 (elevated) on the host.' 'Green'
}

function Sync-MastSystemTime {
    # REDUNDANT best-effort clock fix. The AUTHORITATIVE one-time correction
    # happens later, during provisioning, via the 'timesync' provider
    # (server/providers/timesync), which syncs from the provisioning server's NTP
    # server -- reachable even when the unit cannot reach public NTP. This step is
    # a backstop run at bootstrap time (before provisioning exists): a freshly
    # imaged / long-powered-off unit often has a wrong clock, and a skewed clock
    # breaks TLS, so we try public NTP here too. It frequently CANNOT sync (UDP
    # 123 blocked / no route) -- that is expected; it warns and continues, and the
    # provisioning timesync provider does the real fix. Never aborts bootstrap.
    [CmdletBinding()]
    param([string[]]$NtpServers = @('ntp.weizmann.ac.il', 'ntp2.weizmann.ac.il', 'time.windows.com', 'pool.ntp.org', 'time.google.com'))

    $peerList = ($NtpServers -join ' ')
    try {
        Set-Service -Name w32time -StartupType Automatic -ErrorAction Stop
        # w32time will not start while the only time source is the (default) local
        # CMOS clock on a non-domain box; configuring a manual NTP peer list fixes that.
        Start-Service -Name w32time -ErrorAction SilentlyContinue
        & w32tm.exe /config /manualpeerlist:"$peerList" /syncfromflags:manual /reliable:no /update | Out-Null
        Restart-Service -Name w32time -ErrorAction SilentlyContinue

        # IMPORTANT: 'w32tm /resync' returns success even when NO NTP reply ever
        # arrives -- it silently keeps the Local CMOS Clock. So do not trust the
        # exit code; query the service and confirm it actually locked onto an NTP
        # source. (Observed on mast02: UDP 123 blocked -> Source stayed 'Local
        # CMOS Clock', clock 5 min slow, yet /resync "succeeded".)
        # Right after the service restart the first poll has usually not completed
        # yet, so a single immediate status check reports 'Local CMOS Clock' even
        # when NTP is reachable -- resync + wait + check, with retries (same
        # proven pattern as the provisioning timesync provider).
        $source = ''
        $lastSync = ''
        $synced = $false
        for ($attempt = 1; $attempt -le 3 -and -not $synced; $attempt++) {
            & w32tm.exe /resync /force | Out-Null
            Start-Sleep -Seconds 2
            $status   = & w32tm.exe /query /status 2>$null
            $srcLine  = ($status | Select-String -Pattern 'Source:\s*(.+)$')
            $lastLine = ($status | Select-String -Pattern 'Last Successful Sync Time:\s*(.+)$')
            $source   = if ($srcLine)  { $srcLine.Matches[0].Groups[1].Value.Trim() }  else { '' }
            $lastSync = if ($lastLine) { $lastLine.Matches[0].Groups[1].Value.Trim() } else { '' }
            $synced = [bool]($source -and ($source -notmatch 'Local CMOS Clock') -and ($source -notmatch 'Free-running') `
                      -and $lastSync -and ($lastSync -notmatch 'unspecified'))
            if (-not $synced) {
                Write-BootstrapMsg ("  resync attempt {0}/3: not locked yet (Source='{1}')." -f $attempt, $source) 'DarkGray'
            }
        }
        if ($synced) {
            Write-BootstrapMsg ("  Time synced. Source={0}; clock now {1}." -f $source, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) 'Green'
        } else {
            Write-BootstrapMsg '  [WARN] NTP did NOT actually sync -- the time service is still on the local clock.' 'Yellow'
            Write-BootstrapMsg ("         Source='{0}' LastSuccessfulSync='{1}'. UDP 123 is likely blocked or there is no route to the NTP servers." -f $source, $lastSync) 'Yellow'
            Write-BootstrapMsg '         A wrong clock breaks TLS validation, so the provisioning git clone (HTTPS) will fail.' 'Yellow'
            Write-BootstrapMsg '         FIX one of: open outbound UDP 123; point w32time at a reachable NTP source' 'Yellow'
            Write-BootstrapMsg '         (e.g. the prov server: w32tm /config /manualpeerlist:"<provIP>" /syncfromflags:manual /update; w32tm /resync); or set the clock manually.' 'Yellow'
        }
    } catch {
        Write-BootstrapMsg ("  [WARN] time sync failed ({0}); continuing. Fix the clock manually if TLS/git later fails." -f $_.Exception.Message) 'Yellow'
    }
}

# en-US 'Control Panel\International' value set. These are the exact registry
# values Windows writes when you pick "English (United States)" as the Region >
# Regional format. Strings (REG_SZ) only -- there are no DWORDs under this key.
$script:IntlEnUsValues = @{
    'LocaleName'       = 'en-US'
    'Locale'           = '00000409'
    's1159'            = 'AM'
    's2359'            = 'PM'
    'sCountry'         = 'United States'
    'sCurrency'        = '$'
    'sDate'            = '/'
    'sDecimal'         = '.'
    'sGrouping'        = '3;0'
    'sLanguage'        = 'ENU'
    'sList'            = ','
    'sLongDate'        = 'dddd, MMMM d, yyyy'
    'sMonDecimalSep'   = '.'
    'sMonGrouping'     = '3;0'
    'sMonThousandSep'  = ','
    'sNativeDigits'    = '0123456789'
    'sNegativeSign'    = '-'
    'sPositiveSign'    = ''
    'sShortDate'       = 'M/d/yyyy'
    'sShortTime'       = 'h:mm tt'
    'sThousand'        = ','
    'sTime'            = ':'
    'sTimeFormat'      = 'h:mm:ss tt'
    'sYearMonth'       = 'MMMM yyyy'
    'iCalendarType'    = '1'
    'iCountry'         = '1'
    'iCurrDigits'      = '2'
    'iCurrency'        = '0'
    'iDate'            = '0'
    'iDigits'          = '2'
    'iFirstDayOfWeek'  = '6'
    'iFirstWeekOfYear' = '0'
    'iLZero'           = '1'
    'iMeasure'         = '1'
    'iNegCurr'         = '0'
    'iNegNumber'       = '1'
    'iPaperSize'       = '1'
    'iTime'            = '0'
    'iTimePrefix'      = '0'
    'iTLZero'          = '0'
}

function Set-MastIntlValues {
    # Write the en-US 'Control Panel\International' values under a single
    # registry root. $RootPath is a PowerShell registry path WITHOUT the
    # trailing 'Control Panel\International' subkey, e.g. 'HKCU:',
    # 'Registry::HKEY_USERS\.DEFAULT', or 'Registry::HKU\<loaded-hive-key>'.
    param([string]$RootPath, [hashtable]$Values)
    $intlPath = Join-Path $RootPath 'Control Panel\International'
    if (-not (Test-Path $intlPath)) {
        New-Item -Path $intlPath -Force -ErrorAction SilentlyContinue | Out-Null
    }
    foreach ($name in $Values.Keys) {
        Set-ItemProperty -Path $intlPath -Name $name -Value $Values[$name] -Type String -Force -ErrorAction Stop
    }
}

$exitCode = 0
try {
    Write-BootstrapBanner '======================================================================' 'Cyan'
    Write-BootstrapBanner ' MAST bootstrap-winrm.ps1 (manual first-time setup)' 'Cyan'
    Write-BootstrapBanner '======================================================================' 'Cyan'
    Write-BootstrapMsg ("Log file (append): {0}" -f $script:BootstrapLog) 'DarkGray'

    if ([string]::IsNullOrWhiteSpace($MastHostName)) {
        if ($NonInteractive) {
            throw "Pass -MastHostName mastNN (required when -NonInteractive is set)."
        }
        Write-BootstrapMsg '' 'White'
        Write-BootstrapMsg 'UNIT HOSTNAME (Windows computer name)' 'Yellow'
        Write-BootstrapMsg '  Examples: mast01, mast05. Max 15 characters; letters, digits, hyphen only.' 'Yellow'
        Write-BootstrapMsg '  This name must match what the provisioning server will use in DNS/hosts.' 'Yellow'
        $MastHostName = Read-Host 'Enter MastHostName'
    }
    $MastHostName = $MastHostName.Trim()
    if ($MastHostName -notmatch '^[A-Za-z0-9-]{1,15}$') {
        throw "Invalid MastHostName '$MastHostName'. Use 1-15 characters: letters, digits, hyphen."
    }
    Write-BootstrapMsg ("Using MastHostName (computer rename target): {0}" -f $MastHostName) 'White'

    # Site selection -- drives the provisioning config profile (config-bootstrap).
    # Like the hostname, it is the operator's explicit choice, NEVER derived from the
    # hostname. Persisted to C:\ProgramData\MAST\site.txt so onboard-mast-unit.ps1 can
    # record it in the prov server's unit-registry.json.
    #
    # SINGLE SOURCE OF TRUTH for the site list is server\providers\config-bootstrap\
    # sites\*.toml. This script runs offline on a bare unit (USB/ISO) before the prov
    # server is reachable, so it cannot enumerate that directory and must embed the
    # list below for early operator validation at the console. build-mast.ps1 runs
    # Assert-BootstrapKnownSitesInSync on the prov server (where both are visible) and
    # FAILS THE BUILD if this list drifts from sites\*.toml -- so keep the two in sync
    # (add a site by dropping sites\<code>.toml AND adding <code> here).
    $knownSites = @('ns', 'wis')
    if ([string]::IsNullOrWhiteSpace($Site)) {
        if ($NonInteractive) {
            throw "Pass -Site <site> (one of: $($knownSites -join ', ')) when -NonInteractive is set."
        }
        Write-BootstrapMsg '' 'White'
        Write-BootstrapMsg 'SITE (selects the unit configuration profile)' 'Yellow'
        Write-BootstrapMsg ('  Known sites: {0}. Default: ns (Neot Smadar).' -f ($knownSites -join ', ')) 'Yellow'
        $Site = Read-Host 'Enter site [ns]'
        if ([string]::IsNullOrWhiteSpace($Site)) { $Site = 'ns' }
    }
    $Site = $Site.Trim().ToLower()
    if ($knownSites -notcontains $Site) {
        throw "Invalid site '$Site'. Known sites: $($knownSites -join ', ') (add a profile under server\providers\config-bootstrap\sites\ and this list to add one)."
    }
    $siteDir = Join-Path $env:ProgramData 'MAST'
    New-Item -ItemType Directory -Path $siteDir -Force | Out-Null
    $siteFile = Join-Path $siteDir 'site.txt'
    Set-Content -LiteralPath $siteFile -Value $Site -Encoding ASCII
    Write-BootstrapMsg ('Using site: {0} (persisted to {1})' -f $Site, $siteFile) 'White'

    # --- Sync system time with public NTP (before anything TLS-sensitive) ---
    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Sync system time (NTP) ---' 'Cyan'
    Sync-MastSystemTime

    # --- OEM factory account: leave intact, create fresh 'mast' instead ---
    #
    # Previous behavior renamed the OEM account ('user') to 'mast' in place.
    # That left %USERPROFILE% pointing at C:\Users\user even after the rename
    # (Windows does not migrate the profile directory on Rename-LocalUser), so
    # everything hard-coded to C:\Users\mast silently broke on the VM. See
    # compare-mastw/GAPS.md (2026-05-18) "Profile-dir anomaly on the VM".
    #
    # New policy: create a brand-new local 'mast' account (block below). The
    # OEM account is left untouched. The -FactoryUser parameter is preserved
    # for backward compatibility but is now a no-op.
    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- OEM factory account policy ---' 'Cyan'
    $RenamedOemToMast = $false
    if ($FactoryUser) {
        Write-BootstrapMsg "  -FactoryUser is deprecated and ignored; OEM '$FactoryUser' is left intact." 'DarkGray'
        Write-BootstrapMsg "  A separate '$MastUser' account will be created/ensured below." 'DarkGray'
    }

    # --- mast admin ---
    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Ensuring local admin mast ---' 'Cyan'
    $secPwd = ConvertTo-SecureString $MastPassword -AsPlainText -Force
    $existing = Get-LocalUser -Name $MastUser -ErrorAction SilentlyContinue
    if ($existing) {
        Set-LocalUser -Name $MastUser -Password $secPwd -PasswordNeverExpires $true -FullName $MastUser
        Write-BootstrapMsg "  Password and display name synced for '$MastUser'." 'Green'
    } else {
        New-LocalUser -Name $MastUser -Password $secPwd `
            -FullName $MastUser -PasswordNeverExpires `
            -UserMayNotChangePassword | Out-Null
        Write-BootstrapMsg "  Created local user '$MastUser'." 'Green'
    }
    $mastSid = (Get-LocalUser -Name $MastUser).Sid
    $alreadyAdmin = $false
    foreach ($m in @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue)) {
        if ($m.SID -eq $mastSid) { $alreadyAdmin = $true; break }
    }
    if (-not $alreadyAdmin) {
        try {
            Add-LocalGroupMember -Group 'Administrators' -Member $MastUser -ErrorAction Stop
            Write-BootstrapMsg "  Added '$MastUser' to Administrators." 'Green'
        } catch {
            $fe = $_.FullyQualifiedErrorId
            if ($fe -notmatch 'MemberExists|ResourceExists') { throw }
            Write-BootstrapMsg "  '$MastUser' already in Administrators." 'DarkGray'
        }
    } else {
        Write-BootstrapMsg "  '$MastUser' already an Administrator." 'DarkGray'
    }

    # --- Auto-logon: log the mast account in automatically at boot ---
    # MAST units are headless control boxes: after any reboot the mast account must log
    # in unattended so the control stack (which lives in the interactive desktop session,
    # not as a Windows service) comes back up without a console operator. Configured via
    # the classic Winlogon AutoAdminLogon registry values (HKLM). The password is stored
    # in plaintext under DefaultPassword -- acceptable here because the mast account uses
    # the well-known non-secret fleet default and units sit on an isolated VLAN; Sysinternals
    # Autologon (LSA secret) is the hardening path if that ever changes.
    if ($SkipAutoLogon) {
        Write-BootstrapMsg '' 'Cyan'
        Write-BootstrapMsg '--- Skipping auto-logon (-SkipAutoLogon) ---' 'Yellow'
    } else {
        Write-BootstrapMsg '' 'Cyan'
        Write-BootstrapMsg "--- Configuring auto-logon for '$MastUser' ---" 'Cyan'
        # DefaultDomainName must match the machine's eventual name. The rename below
        # changes it, so use the target hostname when a rename is pending.
        $autoLogonDomain = if (-not $SkipComputerRename -and $MastHostName) { $MastHostName } else { $env:COMPUTERNAME }
        $winlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty -Path $winlogonKey -Name 'AutoAdminLogon'    -Value '1'              -Type String
        Set-ItemProperty -Path $winlogonKey -Name 'DefaultUserName'   -Value $MastUser        -Type String
        Set-ItemProperty -Path $winlogonKey -Name 'DefaultPassword'   -Value $MastPassword    -Type String
        Set-ItemProperty -Path $winlogonKey -Name 'DefaultDomainName' -Value $autoLogonDomain -Type String
        # AutoLogonCount decrements each boot and disables auto-logon at zero; ForceAutoLogon
        # and a stale AutoLogonSID can fight a clean unattended logon. Clear them so auto-logon
        # is permanent and tied to the credentials above.
        foreach ($stale in 'AutoLogonCount', 'AutoLogonSID', 'ForceAutoLogon') {
            Remove-ItemProperty -Path $winlogonKey -Name $stale -ErrorAction SilentlyContinue
        }
        Write-BootstrapMsg "  AutoAdminLogon enabled for '$MastUser' (DefaultDomainName=$autoLogonDomain)." 'Green'
    }

    # --- Windows Update policy ---
    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Suppressing Windows Update (provisioning window) ---' 'Cyan'
    Disable-WindowsAutoUpdate
    Write-BootstrapMsg '  Windows Update service disabled for AUOptions=1.' 'Green'

    # --- Suppress Windows popup notifications ---
    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Suppressing Windows popup notifications ---' 'Cyan'

    # Machine-wide consumer cloud content ("Get even more out of Windows" nags) is
    # disabled in the telemetry/privacy hardening table below (DisableWindowsConsumerFeatures),
    # so it is not duplicated here. This section keeps the per-user (HKCU) toast /
    # content-delivery suppressions and the backup-reminder task disable.

    # Machine-wide: disable Windows Backup scheduled tasks that trigger backup reminder popups
    foreach ($taskName in @('Automatic Backup', 'ConfigNotification')) {
        try {
            $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\WindowsBackup\' `
                -TaskName $taskName -ErrorAction SilentlyContinue
            if ($t) {
                Disable-ScheduledTask -TaskPath '\Microsoft\Windows\WindowsBackup\' `
                    -TaskName $taskName -ErrorAction SilentlyContinue | Out-Null
                Write-BootstrapMsg ("  Disabled backup task: {0}" -f $taskName) 'Green'
            }
        } catch { }
    }

    # Apply HKCU notification suppressions for the mast user.
    # Load the hive if mast is not the current user (bootstrap typically runs as a different user).
    $mastProfilePath = ''
    try {
        $mastProfilePath = (Get-LocalUser -Name $MastUser -ErrorAction Stop |
            ForEach-Object {
                $sid = $_.SID.Value
                $p = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
                if (Test-Path $p) { (Get-ItemProperty -Path $p).ProfileImagePath } else { '' }
            })
    } catch { }

    $hiveLoaded = $false
    $hivePath = ''
    if ($mastProfilePath -and (Test-Path (Join-Path $mastProfilePath 'NTUSER.DAT'))) {
        $hivePath = Join-Path $mastProfilePath 'NTUSER.DAT'
        $hiveKey = 'HKU\MAST_BOOTSTRAP_HIVE'
        try {
            & reg.exe load $hiveKey $hivePath 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $hiveLoaded = $true }
        } catch { }
    }

    # Helper: set a DWORD in either HKU hive (if loaded) or HKCU (if running as mast already)
    function Set-MastHkcu {
        param([string]$SubKey, [string]$Name, [int]$Value)
        $fullPath = if ($hiveLoaded) { "Registry::HKU\MAST_BOOTSTRAP_HIVE\$SubKey" } else { "HKCU:\$SubKey" }
        try {
            New-Item -Path $fullPath -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path $fullPath -Name $Name -Value $Value -Type DWord -Force -ErrorAction Stop
        } catch {
            Write-BootstrapMsg ("  WARN: could not set HKCU\{0}\{1}: {2}" -f $SubKey, $Name, $_.Exception.Message) 'Yellow'
        }
    }

    # Disable toast notifications
    Set-MastHkcu 'Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0

    # Disable tips, "Get started", spotlight, content delivery subscriptions
    $cdm = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    Set-MastHkcu $cdm 'SoftLandingEnabled'                  0
    Set-MastHkcu $cdm 'SubscribedContent-338389Enabled'     0
    Set-MastHkcu $cdm 'SubscribedContent-310093Enabled'     0
    Set-MastHkcu $cdm 'SubscribedContent-338388Enabled'     0
    Set-MastHkcu $cdm 'RotatingLockScreenEnabled'           0
    Set-MastHkcu $cdm 'OemPreInstalledAppsEnabled'          0
    Set-MastHkcu $cdm 'PreInstalledAppsEnabled'             0
    Set-MastHkcu $cdm 'SilentInstalledAppsEnabled'          0
    Set-MastHkcu $cdm 'SystemPaneSuggestionsEnabled'        0

    if ($hiveLoaded) {
        try {
            & reg.exe unload 'HKU\MAST_BOOTSTRAP_HIVE' 2>&1 | Out-Null
        } catch { }
    }

    Write-BootstrapMsg '  Windows popup/notification suppressions applied.' 'Green'

    # --- Regional format: English (United States) ---
    #
    # Pin the Windows regional format (Settings > Time & language > Region >
    # Regional format) to English (United States) / locale en-US, instead of
    # whatever the OEM image shipped. This controls how dates, times, numbers,
    # and currency are formatted; a non-US short-date or decimal separator has
    # bitten log/CSV parsing in this fleet before, so we pin it.
    #
    # Applied at three levels:
    #   * Set-WinSystemLocale en-US  - system (non-Unicode) locale + new-user
    #                                  default. Needs a reboot to fully apply.
    #   * Set-WinHomeLocation 244    - home location = United States.
    #   * 'Control Panel\International' values written to every user scope:
    #       - the current user (HKCU) running bootstrap
    #       - the .DEFAULT hive (logon screen / SYSTEM)
    #       - the Default-user profile template (seeds NEW profiles, incl. mast
    #         at first login -- a freshly created account has no hive yet)
    #       - the mast account hive, if its profile already exists
    # Idempotent; safe to re-run.
    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Regional format: English (United States) ---' 'Cyan'

    try {
        Set-WinSystemLocale -SystemLocale en-US -ErrorAction Stop
        Write-BootstrapMsg '  System locale set to en-US (reboot required to fully apply).' 'Green'
        $script:RebootRecommended = $true
    } catch {
        Write-BootstrapMsg ("  WARN: Set-WinSystemLocale en-US failed: {0}" -f $_.Exception.Message) 'Yellow'
    }
    try {
        Set-WinHomeLocation -GeoId 244 -ErrorAction Stop   # 244 = United States
        Write-BootstrapMsg '  Home location set to United States (GeoId 244).' 'Green'
    } catch {
        Write-BootstrapMsg ("  WARN: Set-WinHomeLocation 244 failed: {0}" -f $_.Exception.Message) 'Yellow'
    }

    # Per-user International values. Directly write the always-mounted roots,
    # then load/apply/unload the on-disk hives (Default-user template + mast).
    $intlScopes = 0
    foreach ($root in @('HKCU:', 'Registry::HKEY_USERS\.DEFAULT')) {
        try {
            Set-MastIntlValues -RootPath $root -Values $script:IntlEnUsValues
            $intlScopes++
        } catch {
            Write-BootstrapMsg ("  WARN: International values on {0}: {1}" -f $root, $_.Exception.Message) 'Yellow'
        }
    }

    $intlHiveTargets = @()
    $defaultDat = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (Test-Path -LiteralPath $defaultDat) {
        $intlHiveTargets += @{ Label = 'Default-user template'; Dat = $defaultDat; Key = 'MAST_INTL_DEFAULT' }
    } else {
        Write-BootstrapMsg ("  WARN: Default-user hive not found at {0}; new profiles will not inherit en-US." -f $defaultDat) 'Yellow'
    }
    try {
        $mastSidVal = (Get-LocalUser -Name $MastUser -ErrorAction Stop).SID.Value
        $mastPl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$mastSidVal"
        if (Test-Path $mastPl) {
            $mastProf = (Get-ItemProperty -Path $mastPl).ProfileImagePath
            $mastDat = Join-Path $mastProf 'NTUSER.DAT'
            if (Test-Path -LiteralPath $mastDat) {
                $intlHiveTargets += @{ Label = "mast user ($MastUser)"; Dat = $mastDat; Key = 'MAST_INTL_MAST' }
            }
        }
    } catch { }
    if (-not ($intlHiveTargets | Where-Object { $_.Key -eq 'MAST_INTL_MAST' })) {
        Write-BootstrapMsg "  mast profile not created yet; it will inherit en-US from the Default-user template at first login." 'DarkGray'
    }

    foreach ($h in $intlHiveTargets) {
        $loaded = $false
        try {
            & reg.exe load ("HKU\{0}" -f $h.Key) $h.Dat 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $loaded = $true }
        } catch { }
        if (-not $loaded) {
            Write-BootstrapMsg ("  WARN: could not load {0} hive ({1}); skipping." -f $h.Label, $h.Dat) 'Yellow'
            continue
        }
        try {
            Set-MastIntlValues -RootPath ("Registry::HKU\{0}" -f $h.Key) -Values $script:IntlEnUsValues
            $intlScopes++
        } catch {
            Write-BootstrapMsg ("  WARN: International values on {0}: {1}" -f $h.Label, $_.Exception.Message) 'Yellow'
        } finally {
            # Drop our references before unloading or reg.exe reports the hive busy.
            [System.GC]::Collect()
            try { & reg.exe unload ("HKU\{0}" -f $h.Key) 2>&1 | Out-Null } catch { }
        }
    }
    Write-BootstrapMsg ("  en-US regional format applied to {0} user scope(s)." -f $intlScopes) 'Green'

    # --- Hardening: telemetry / privacy ---
    #
    # Machine-wide HKLM policy keys plus the two diagnostic-upload services.
    # Adapted from the standalone Disable-MastTelemetry hardening script.
    # AllowTelemetry=0 ("Security" tier) is only honored on Enterprise/Education/IoT
    # SKUs -- which this fleet is (Win10 IoT Enterprise LTSC 2021). Idempotent.
    #
    # NOTE: the source script also carried Windows Update reboot-control keys
    # (active hours, NoAutoRebootWithLoggedOnUsers). Those are intentionally NOT
    # applied here: bootstrap fully disables wuauserv via Disable-WindowsAutoUpdate
    # (see the Windows Update section above), so active-hours keys would be inert.
    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Hardening: telemetry / privacy ---' 'Cyan'

    $dataCollection = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
    $cloudContent   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
    $sys            = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    $search         = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
    $appPrivacy     = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'

    $hardeningReg = @(
        @{ Path = $dataCollection; Name = 'AllowTelemetry';                Value = 0; Desc = 'Diagnostic data = Security (lowest)' }
        @{ Path = $dataCollection; Name = 'DoNotShowFeedbackNotifications'; Value = 1; Desc = 'No feedback prompts' }
        @{ Path = $dataCollection; Name = 'AllowDeviceNameInTelemetry';     Value = 0; Desc = 'No device name in telemetry' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'; Name = 'Disabled'; Value = 1; Desc = 'Windows Error Reporting off' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'; Name = 'DisabledByGroupPolicy'; Value = 1; Desc = 'Advertising ID off' }
        @{ Path = $sys;            Name = 'EnableActivityFeed';            Value = 0; Desc = 'Activity feed off' }
        @{ Path = $sys;            Name = 'PublishUserActivities';         Value = 0; Desc = 'No activity publishing' }
        @{ Path = $sys;            Name = 'UploadUserActivities';          Value = 0; Desc = 'No activity upload' }
        @{ Path = $cloudContent;   Name = 'DisableWindowsConsumerFeatures'; Value = 1; Desc = 'No consumer features' }
        @{ Path = $cloudContent;   Name = 'DisableSoftLanding';            Value = 1; Desc = 'No tips / soft landing' }
        @{ Path = $cloudContent;   Name = 'DisableConsumerAccountStateContent'; Value = 1; Desc = 'No account suggestions' }
        @{ Path = $search;         Name = 'AllowCortana';                  Value = 0; Desc = 'Cortana off' }
        @{ Path = $search;         Name = 'DisableWebSearch';              Value = 1; Desc = 'No web in Start search' }
        @{ Path = $search;         Name = 'ConnectedSearchUseWeb';         Value = 0; Desc = 'No connected web search' }
        @{ Path = $search;         Name = 'AllowCloudSearch';              Value = 0; Desc = 'No cloud search' }
        @{ Path = $appPrivacy;     Name = 'LetAppsRunInBackground';        Value = 2; Desc = 'Background apps = Force Deny' }
        @{ Path = $appPrivacy;     Name = 'LetAppsAccessLocation';         Value = 2; Desc = 'App location = Force Deny' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode'; Value = 0; Desc = 'Delivery Optimization = HTTP only' }
    )

    $hardeningOk = 0
    foreach ($r in $hardeningReg) {
        try {
            if (-not (Test-Path $r.Path)) { New-Item -Path $r.Path -Force | Out-Null }
            Set-ItemProperty -Path $r.Path -Name $r.Name -Value $r.Value -Type DWord -Force -ErrorAction Stop
            $hardeningOk++
        } catch {
            Write-BootstrapMsg ("  WARN: could not set {0}\{1}: {2}" -f $r.Path, $r.Name, $_.Exception.Message) 'Yellow'
        }
    }
    Write-BootstrapMsg ("  Applied {0}/{1} telemetry/privacy policy keys." -f $hardeningOk, $hardeningReg.Count) 'Green'

    # Diagnostic-upload services: stop + disable so AllowTelemetry=0 is not undermined.
    foreach ($svc in @('DiagTrack', 'dmwappushservice')) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($null -eq $s) {
            Write-BootstrapMsg ("  Service '{0}' not present; skipping." -f $svc) 'DarkGray'
            continue
        }
        try {
            if ($s.Status -ne 'Stopped') { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue }
            Set-Service -Name $svc -StartupType Disabled -ErrorAction Stop
            Write-BootstrapMsg ("  Service '{0}' stopped + disabled." -f $svc) 'Green'
        } catch {
            Write-BootstrapMsg ("  WARN: could not disable service '{0}': {1}" -f $svc, $_.Exception.Message) 'Yellow'
        }
    }

    # --- Trim non-essential / vendor services ---
    #
    # Stops + disables the services in $script:TrimList (Print Spooler, Windows
    # Search, Intel LMS, ASUS / Intel GCC / Realtek helpers) that have no role on
    # a headless control box. Applied by default; exempt specific services with
    # -SkipTrim. Names vary by driver version, so Resolve-MastTrimService falls
    # back to a display-name pattern; a service that resolves to neither is
    # reported "not present" and skipped. Idempotent.
    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Trimming non-essential / vendor services ---' 'Cyan'
    $trimmed = 0
    foreach ($t in $script:TrimList) {
        if ($SkipTrim -contains $t.Name) {
            Write-BootstrapMsg ("  Skipping '{0}' (-SkipTrim): {1}" -f $t.Name, $t.Desc) 'DarkGray'
            continue
        }
        $s = Resolve-MastTrimService $t
        if ($null -eq $s) {
            Write-BootstrapMsg ("  '{0}' not present; skipping. ({1})" -f $t.Name, $t.Desc) 'DarkGray'
            continue
        }
        try {
            if ($s.Status -ne 'Stopped') { Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue }
            Set-Service -Name $s.Name -StartupType Disabled -ErrorAction Stop
            Write-BootstrapMsg ("  '{0}' stopped + disabled. ({1})" -f $s.Name, $t.Desc) 'Green'
            $trimmed++
        } catch {
            Write-BootstrapMsg ("  WARN: could not disable '{0}': {1}" -f $s.Name, $_.Exception.Message) 'Yellow'
        }
    }
    Write-BootstrapMsg ("  Trim complete: {0} service(s) disabled." -f $trimmed) 'Green'

    # --- Network: ensure DHCP for IPv4 (fleet requires DHCP addressing) ---
    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Network: ensure DHCP for IPv4 ---' 'Cyan'
    Set-MastAdaptersToDhcp

    # --- WinRM ---
    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Enabling WinRM (HTTP, Basic) ---' 'Cyan'
    Write-BootstrapMsg '  Setting connection profiles to Private (best-effort)...' 'DarkGray'
    try {
        $profiles = @(Get-NetConnectionProfile -ErrorAction Stop)
        foreach ($p in $profiles) {
            try {
                Set-NetConnectionProfile -InputObject $p -NetworkCategory Private -ErrorAction Stop
            } catch {
                Write-BootstrapMsg ("  WARN: profile '{0}': {1}" -f $p.Name, $_.Exception.Message) 'Yellow'
            }
        }
    } catch {
        Write-BootstrapMsg ("  WARN: Get-NetConnectionProfile: {0}" -f $_.Exception.Message) 'Yellow'
    }
    try {
        foreach ($a in @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
            try {
                $p = Get-NetConnectionProfile -InterfaceIndex $a.ifIndex -ErrorAction Stop
                Set-NetConnectionProfile -InputObject $p -NetworkCategory Private -ErrorAction Stop
            } catch { }
        }
    } catch {
        Write-BootstrapMsg ("  WARN: per-adapter profile: {0}" -f $_.Exception.Message) 'Yellow'
    }
    $nlProfiles = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles'
    if (Test-Path $nlProfiles) {
        Get-ChildItem $nlProfiles -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Set-ItemProperty -LiteralPath $_.PSPath -Name 'Category' -Value 1 -Type DWord -Force -ErrorAction Stop
            } catch { }
        }
        Write-BootstrapMsg '  Registry fallback: NetworkList Profiles Category=Private where possible.' 'DarkGray'
    }
    try {
        Restart-Service nlasvc -Force -ErrorAction Stop
        Start-Sleep -Seconds 3
    } catch { }

    Enable-PSRemoting -Force -SkipNetworkProfileCheck
    Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true -Force
    try {
        Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true -Force
        $script:AllowUnencryptedOk = $true
    } catch {
        Write-BootstrapMsg ("  WARN: AllowUnencrypted not set: {0}" -f $_.Exception.Message) 'Yellow'
        try { Restart-Service nlasvc -Force; Start-Sleep -Seconds 4 } catch { }
        try {
            Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true -Force
            $script:AllowUnencryptedOk = $true
        } catch {
            Write-BootstrapMsg ("  WARN: AllowUnencrypted still not set: {0}" -f $_.Exception.Message) 'Yellow'
        }
    }
    if (-not $script:AllowUnencryptedOk) {
        Show-BootstrapUserFixNetwork
    }
    Set-Service WinRM -StartupType Automatic
    Write-BootstrapMsg '  WinRM service configured (HTTP listener, Basic auth).' 'Green'

    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- LocalAccountTokenFilterPolicy (remote local admin) ---' 'Cyan'
    $polPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    New-ItemProperty -Path $polPath -Name LocalAccountTokenFilterPolicy `
        -Value 1 -PropertyType DWord -Force | Out-Null
    Restart-Service WinRM
    Write-BootstrapMsg '  LocalAccountTokenFilterPolicy=1 applied; WinRM restarted.' 'Green'

    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Firewall TCP 5985 ---' 'Cyan'
    Ensure-MastWinRmFirewallRule5985 -RuleDisplayName 'MAST - WinRM HTTP'

    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Persist Private network profile across reboots ---' 'Cyan'
    try {
        Install-MastNetworkPrivateTask
    } catch {
        Write-BootstrapMsg ("  WARN: could not register MAST-NetworkPrivate task: {0}" -f $_.Exception.Message) 'Yellow'
        Write-BootstrapMsg '  Network may regress to Public after reboot; WinRM Basic could return 401 until re-run.' 'Yellow'
    }

    # --- OpenSSH Server (capability + service + firewall + password auth) ---
    #
    # Installs the Windows in-box OpenSSH.Server optional capability and
    # makes it operational. Owned by bootstrap (not by the openssh-server
    # provider) because Add-WindowsCapability is rejected by DISM/CBS under
    # the WinRM network logon used by the provider pipeline, even when the
    # user is a full admin (the network-logon token isn't enough for
    # CBS_E_NOT_APPLICABLE-style checks). Bootstrap runs interactively as
    # admin, so the install just works here. See compare-mastw/GAPS.md +
    # the 2026-05-25 DECISIONS entry.
    #
    # Steps mirrored from the previous provide-openssh-server.ps1:
    #   1. Add-WindowsCapability OpenSSH.Server (idempotent)
    #   2. Set sshd Automatic, Start-Service
    #   3. Same for ssh-agent (helpful, not strictly required)
    #   4. Firewall: inbound TCP 22 (using the same helper as 5985)
    #   5. sshd_config: assert PasswordAuthentication yes (matches mastw's
    #      working entry point of mast / physics over SSH)
    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- OpenSSH Server ---' 'Cyan'
    try {
        $sshCap = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop
        if ($sshCap.State -ne 'Installed') {
            Write-BootstrapMsg ("  Adding OpenSSH.Server capability (current state: {0})..." -f $sshCap.State) 'White'
            Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop | Out-Null
            Write-BootstrapMsg '  OpenSSH.Server capability installed.' 'Green'
        } else {
            Write-BootstrapMsg '  OpenSSH.Server capability already installed.' 'DarkGray'
        }
    } catch {
        Write-BootstrapMsg ("  WARN: Add-WindowsCapability failed: {0}" -f $_.Exception.Message) 'Yellow'
        Write-BootstrapMsg '  SSH provider verify on this unit will fail until the capability is installed by another means.' 'Yellow'
    }

    foreach ($svc in @('sshd', 'ssh-agent')) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($null -eq $s) {
            Write-BootstrapMsg ("  Service '{0}' not registered (capability install failed?); skipping." -f $svc) 'Yellow'
            continue
        }
        try {
            Set-Service -Name $svc -StartupType Automatic -ErrorAction Stop
            if ($s.Status -ne 'Running') {
                Start-Service -Name $svc -ErrorAction Stop
            }
            Write-BootstrapMsg ("  {0}: StartType=Automatic, Status=Running." -f $svc) 'Green'
        } catch {
            Write-BootstrapMsg ("  WARN: configuring '{0}' failed: {1}" -f $svc, $_.Exception.Message) 'Yellow'
        }
    }

    # Inbound TCP 22. Reuse the firewall-rule pattern from 5985.
    $sshFwRule = 'MAST OpenSSH Server (TCP 22)'
    if (Test-MastNetFirewallRuleExists -DisplayName $sshFwRule) {
        Write-BootstrapMsg "  Firewall rule '$sshFwRule' already exists." 'DarkGray'
    } else {
        try {
            New-NetFirewallRule -DisplayName $sshFwRule `
                -Direction Inbound -Protocol TCP -LocalPort 22 `
                -Action Allow -Profile Any -ErrorAction Stop | Out-Null
            Write-BootstrapMsg "  Firewall rule '$sshFwRule' created." 'Green'
        } catch {
            Write-BootstrapMsg ("  WARN: New-NetFirewallRule for TCP 22 failed: {0}" -f $_.Exception.Message) 'Yellow'
        }
    }

    # sshd_config: assert PasswordAuthentication yes. Touch the file only if
    # needed so the run stays idempotent. mastw uses password auth as the
    # canonical entry point (mast / physics over SSH).
    $sshdCfg = 'C:\ProgramData\ssh\sshd_config'
    if (Test-Path -LiteralPath $sshdCfg) {
        try {
            $cfg = Get-Content -LiteralPath $sshdCfg -Raw -Encoding UTF8
            $new = $cfg
            if ($new -match '(?m)^\s*PasswordAuthentication\s+no\b') {
                $new = [regex]::Replace($new, '(?m)^\s*PasswordAuthentication\s+no\b', 'PasswordAuthentication yes')
            }
            if ($new -notmatch '(?m)^\s*PasswordAuthentication\s+yes\b') {
                $new = $new.TrimEnd() + "`r`nPasswordAuthentication yes`r`n"
            }
            if ($new -ne $cfg) {
                Set-Content -LiteralPath $sshdCfg -Value $new -Encoding UTF8
                Restart-Service -Name 'sshd' -Force -ErrorAction SilentlyContinue
                Write-BootstrapMsg "  sshd_config: PasswordAuthentication asserted yes (sshd restarted)." 'Green'
            } else {
                Write-BootstrapMsg '  sshd_config: PasswordAuthentication already yes; no change.' 'DarkGray'
            }
        } catch {
            Write-BootstrapMsg ("  WARN: sshd_config patch failed: {0}" -f $_.Exception.Message) 'Yellow'
        }
    } else {
        Write-BootstrapMsg ("  sshd_config not found at {0} (capability may have failed earlier)." -f $sshdCfg) 'Yellow'
    }

    # --- Windows Firewall: disable (perimeter-protected fleet) ---
    #
    # MAST units sit on an isolated VLAN behind a perimeter firewall and need open
    # intra-fleet traffic (COM/RPC, Prometheus scraping, the control stack), so the
    # host Windows Firewall is turned off on all three profiles. The explicit
    # 5985 (WinRM) and 22 (SSH) inbound rules added above are kept deliberately:
    # they are harmless while the firewall is off and keep both services reachable
    # immediately if the firewall is ever re-enabled. See DECISIONS.md.
    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Windows Firewall: disable (perimeter-protected) ---' 'Cyan'
    try {
        Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled False -ErrorAction Stop
        Write-BootstrapMsg '  Windows Firewall disabled on Domain, Private, Public profiles.' 'Green'
    } catch {
        Write-BootstrapMsg ("  WARN: could not disable Windows Firewall via Set-NetFirewallProfile: {0}" -f $_.Exception.Message) 'Yellow'
        $fwCmd = 'netsh advfirewall set allprofiles state off'
        $null = cmd.exe /c $fwCmd 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-BootstrapMsg '  Windows Firewall disabled via netsh advfirewall (fallback).' 'Green'
        } else {
            Write-BootstrapMsg ("  WARN: netsh advfirewall fallback also failed (exit {0}); firewall may still be on." -f $LASTEXITCODE) 'Yellow'
        }
    }

    # --- Npcap packet-capture driver ---
    #
    # Installed here (interactive bootstrap, full unfiltered admin token) rather
    # than by the npcap provider over WinRM. The free Npcap edition has no
    # working silent mode: /S and the feature flags are OEM-edition-only, so the
    # installer always shows its InstallOptions page. Under the WinRM provider
    # pipeline that page can never be dismissed (Session 0 is non-interactive,
    # and the network-logon token has BUILTIN\Administrators filtered out of its
    # effective groups, which the kernel-driver install also needs). Running the
    # GUI here, with the operator present, sidesteps both problems. The npcap
    # provider is now a post-bootstrap presence check + npcapwatchdog task.
    # See DECISIONS.md 2026-05-27.
    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Npcap packet-capture driver ---' 'Cyan'
    $npcapSvc = Get-Service -Name 'npcap' -ErrorAction SilentlyContinue
    if ($null -ne $npcapSvc) {
        Write-BootstrapMsg ("  Npcap service already present (Status={0}); skipping install." -f $npcapSvc.Status) 'DarkGray'
    } else {
        # Locate the installer next to this script (ISO root) or under .\assets
        # (client folder layout). Newest version wins if several are present.
        $npcapSearchDirs = @($PSScriptRoot, (Join-Path $PSScriptRoot 'assets'))
        $npcapInstaller = $null
        foreach ($d in $npcapSearchDirs) {
            if (-not (Test-Path -LiteralPath $d)) { continue }
            $hit = Get-ChildItem -LiteralPath $d -Filter 'npcap-*.exe' -File -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
            if ($hit) { $npcapInstaller = $hit.FullName; break }
        }
        if (-not $npcapInstaller) {
            Write-BootstrapMsg '  [WARN] No npcap-*.exe found next to this script or in .\assets.' 'Yellow'
            Write-BootstrapMsg '  Copy the Npcap installer alongside bootstrap-winrm.ps1 and re-run, or install Npcap manually.' 'Yellow'
            Write-BootstrapMsg '  Packet capture (Wireshark, etc.) will not work until Npcap is installed.' 'Yellow'
        } else {
            Write-BootstrapMsg ("  Launching Npcap installer GUI: {0}" -f $npcapInstaller) 'White'
            Write-BootstrapMsg '  Click through the installer; recommended options: WinPcap-compatible mode + loopback support.' 'Yellow'
            try {
                $npcapProc = Start-Process -FilePath $npcapInstaller -PassThru -Wait
                $npcapExit = $null
                try { $npcapExit = $npcapProc.ExitCode } catch { }
                $reSvc = Get-Service -Name 'npcap' -ErrorAction SilentlyContinue
                if ($null -ne $reSvc) {
                    Write-BootstrapMsg ("  Npcap installed (service Status={0}, installer exit={1})." -f $reSvc.Status, $npcapExit) 'Green'
                } else {
                    Write-BootstrapMsg ("  [WARN] Npcap installer exited (code={0}) but the 'npcap' service is not registered." -f $npcapExit) 'Yellow'
                    Write-BootstrapMsg '  Re-run the installer (it is safe to re-run) or check the install was not cancelled.' 'Yellow'
                }
            } catch {
                Write-BootstrapMsg ("  [WARN] Npcap install failed: {0}" -f $_.Exception.Message) 'Yellow'
            }
        }
    }

    # --- Computer rename ---
    if (-not $SkipComputerRename) {
        Write-BootstrapMsg '' 'Cyan'
        Write-BootstrapMsg '--- Computer name ---' 'Cyan'
        $cur = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Name
        if ($cur -ieq $MastHostName) {
            Write-BootstrapMsg ("  Computer name already '{0}'." -f $MastHostName) 'Green'
        } else {
            Rename-Computer -NewName $MastHostName -Force
            Write-BootstrapMsg ("  Renamed computer from '{0}' to '{1}' (pending reboot)." -f $cur, $MastHostName) 'Green'
            $script:RebootRecommended = $true
        }
    } else {
        Write-BootstrapMsg '  Skipped computer rename (-SkipComputerRename).' 'Yellow'
    }

    # --- VM test: route mast-wis-control to host machine ---
    if ($VmTestRun) {
        Write-BootstrapMsg '' 'Cyan'
        Write-BootstrapMsg '--- *** VM TEST ONLY: mast-wis-control hosts entry *** ---' 'Yellow'
        $hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        $marker = '# MAST-VM-TEST-ONLY'
        $entry = "192.168.56.1  mast-wis-control  mast-wis-control.weizmann.ac.il  $marker"
        $hostsContent = Get-Content -LiteralPath $hostsFile -ErrorAction SilentlyContinue
        $filtered = @()
        if ($hostsContent) {
            foreach ($line in $hostsContent) {
                if ($line -notmatch [regex]::Escape($marker)) { $filtered += $line }
            }
        }
        $filtered += ''
        $filtered += '# *** MAST VM TEST ONLY - NOT FOR PRODUCTION USE - REMOVE BEFORE PRODUCTION DEPLOY ***'
        $filtered += $entry
        Set-Content -LiteralPath $hostsFile -Encoding ASCII -Value $filtered
        Write-BootstrapMsg "  Written: $entry" 'Yellow'
        Write-BootstrapMsg '  [WARN] Remove this entry before promoting this VM to production.' 'Red'
    }

    # --- Verification ---
    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Verification ---' 'Cyan'
    try {
        $addrs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
            ForEach-Object { $_.IPAddress })
        Write-BootstrapMsg ("  IPv4: {0}" -f (($addrs | Sort-Object -Unique) -join ', ')) 'White'
    } catch {
        Write-BootstrapMsg ("  IPv4: (query failed: {0})" -f $_.Exception.Message) 'Yellow'
    }
    $tcp = Test-NetConnection -ComputerName '127.0.0.1' -Port 5985 -WarningAction SilentlyContinue
    if (-not $tcp.TcpTestSucceeded) {
        throw 'Local WinRM port 5985 is not accepting connections after configuration.'
    }
    Write-BootstrapMsg '  TCP 5985 responds on localhost.' 'Green'
    if (-not $script:AllowUnencryptedOk) {
        Write-BootstrapMsg '  [WARN] AllowUnencrypted is still not true; pywinrm may fail until network is Private and you re-run or reboot.' 'Yellow'
    }

    Write-BootstrapMsg '  Trim-service state:' 'White'
    foreach ($t in $script:TrimList) {
        $s = Resolve-MastTrimService $t
        if ($null -eq $s) {
            Write-BootstrapMsg ("    {0,-26} (not present)" -f $t.Name) 'DarkGray'
            continue
        }
        $start = (Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $s.Name) -ErrorAction SilentlyContinue).StartMode
        $skip = if ($SkipTrim -contains $t.Name) { ' [skip]' } else { '' }
        Write-BootstrapMsg ("    {0,-26} State={1,-9} StartMode={2}{3}" -f $s.Name, $s.Status, $start, $skip) 'White'
    }

    # Stamp the bootstrap version so the fleet drift report can tell which bootstrap
    # this unit ran (and therefore which newer bootstrap elements it may be missing).
    try {
        $bootStampDir = Join-Path $env:SystemDrive 'MAST'
        if (-not (Test-Path $bootStampDir)) { New-Item -ItemType Directory -Path $bootStampDir -Force | Out-Null }
        $bootStamp = [ordered]@{
            bootstrap_version = $script:BootstrapVersion
            bootstrapped_at   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            hostname          = $MastHostName
            script            = 'bootstrap-winrm.ps1'
        }
        $bootStamp | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bootStampDir 'bootstrap-manifest.json') -Encoding UTF8
        Write-BootstrapMsg ("  Stamped bootstrap version {0} to C:\MAST\bootstrap-manifest.json" -f $script:BootstrapVersion) 'White'
    } catch {
        Write-BootstrapMsg ("  [WARN] could not write bootstrap-manifest.json: {0}" -f $_.Exception.Message) 'Yellow'
    }

    Write-BootstrapBanner '' 'White'
    Write-BootstrapBanner '[OK] MAST bootstrap finished successfully.' 'Green'
    Write-BootstrapBanner '======================================================================' 'Green'
    Write-BootstrapMsg ("  Account: {0} / {1}" -f $MastUser, $MastPassword) 'White'
    Write-BootstrapMsg '  WinRM:   HTTP port 5985 (Basic auth; unencrypted for bootstrap only).' 'White'
    if ($script:RebootRecommended -and -not $RebootAfterBootstrap) {
        Write-BootstrapMsg '' 'Yellow'
        Write-BootstrapMsg '  Reboot recommended before remote tools use the new computer name.' 'Yellow'
        Write-BootstrapMsg '  Re-run this script after reboot is safe (idempotent).' 'Yellow'
    }
    Show-BootstrapNextSteps -HostNm $MastHostName

    Write-BootstrapMsg '' 'Yellow'
    Write-BootstrapMsg 'Apps to uninstall by hand (not services - Settings > Apps):' 'Yellow'
    foreach ($app in $script:AppsToUninstall) {
        Write-BootstrapMsg ("  - {0}" -f $app) 'White'
    }

    if ($RebootAfterBootstrap) {
        Write-BootstrapMsg '' 'Yellow'
        Write-BootstrapMsg 'Reboot in 90 seconds (-RebootAfterBootstrap). Cancel: shutdown.exe /a' 'Yellow'
        & shutdown.exe /r /t 90 /c "MAST bootstrap complete; rebooting."
    }
}
catch {
    $exitCode = 1
    Write-BootstrapMsg '' 'Red'
    Write-BootstrapBanner '[FAIL] MAST bootstrap did not complete.' 'Red'
    Write-BootstrapMsg $_.Exception.Message 'Red'
    Write-BootstrapMsg ('At line: {0}' -f $_.InvocationInfo.PositionMessage) 'DarkRed'
    Write-BootstrapMsg '' 'Yellow'
    Write-BootstrapMsg 'If the error mentions Public network or AllowUnencrypted, fix profiles (see log) and re-run.' 'Yellow'
    Write-BootstrapMsg ("Full log: {0}" -f $script:BootstrapLog) 'Yellow'
}

exit $exitCode
