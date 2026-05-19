#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Manual first-time MAST unit bootstrap: mast admin, WinRM HTTP for prov server, optional computer rename.

.DESCRIPTION
    Run ONCE per machine in an elevated PowerShell session after Windows is installed (physical unit
    from USB, or dev VM after first login). This is NOT run from autounattend FirstLogon anymore.

    The installing operator must supply the unit Windows hostname (e.g. mast05). The script:
      1. Leaves the OEM factory local account (default 'user') intact; creates a separate 'mast' account.
      2. Ensures 'mast' is a local administrator with the provisioning password.
      3. Suppresses Windows Update automatic installs.
      4. Enables WinRM over HTTP (5985) with Basic auth and opens firewall port 5985.
      5. Renames the computer to -MastHostName (reboot required before the new name is live).

    After this script completes successfully, the operator verifies the summary, reboots if prompted,
    then the provisioning server may run prepare-mast-client.ps1 over WinRM (HTTPS, TrustedHosts).

    USB / DVD: copy client\bootstrap-winrm.cmd and bootstrap-winrm.ps1 together (or use the
    autounattend ISO). Double-click bootstrap-winrm.cmd so Windows runs PowerShell (many PCs
    open .ps1 in Notepad by default). Or from an elevated PowerShell:
        cd <folder containing bootstrap-winrm.ps1>
        .\bootstrap-winrm.ps1 -MastHostName mast05

    If you omit -MastHostName, the script prompts interactively (not valid with -NonInteractive).

.PARAMETER MastHostName
    Windows computer name for this unit (mast01 .. mast20). NetBIOS: 1-15 chars, letters/digits/hyphen.

.PARAMETER NonInteractive
    Fail if -MastHostName is missing (for automation); no prompts.

.PARAMETER RebootAfterBootstrap
    After success, schedule a reboot in 90 seconds (recommended after Rename-Computer or if WinRM/CIM was flaky).

.PARAMETER SkipComputerRename
    Do not rename the computer (use only if you will set the name elsewhere).

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
#>

param(
    [string]$FactoryUser = 'user',
    [string]$MastUser = 'mast',
    [string]$MastPassword = 'physics',
    [string]$ProvServerIP = '192.168.56.1',
    [string]$MastHostName = '',
    [switch]$NonInteractive,
    [switch]$RebootAfterBootstrap,
    [switch]$SkipComputerRename,
    [switch]$VmTestRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$_clientUtilDot = Join-Path $PSScriptRoot 'mast-client-util.ps1'
if (Test-Path $_clientUtilDot) { . $_clientUtilDot }

$script:BootstrapLogDir = Join-Path $env:SystemDrive 'MAST\logs'
$script:BootstrapLog = Join-Path $script:BootstrapLogDir 'bootstrap-winrm.log'
$script:RebootRecommended = $false
$script:AllowUnencryptedOk = $false

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
    Write-BootstrapMsg '--- NEXT: hand off to provisioning server ---' 'Green'
    Write-BootstrapMsg "  1) Ensure this PC resolves $HostNm (DNS or hosts on the prov server)." 'Green'
    Write-BootstrapMsg '  2) From the prov server (one line example):' 'Green'
    $pyLine = '    python tools\run-remote-script-winrm.py --host ' + $HostNm +
        ' --vault vault\creds.json --script client\prepare-mast-client.ps1 --invoke-args "-HostName ' +
        $HostNm + ' -Provider ' + $ProvServerIP + '"'
    Write-BootstrapMsg $pyLine 'Green'
    Write-BootstrapMsg '  Dev VM on VirtualBox host-only: run tools\sync-dev-unit-hosts.ps1 (elevated) on the host.' 'Green'
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

    # --- Windows Update policy ---
    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Suppressing Windows Update (provisioning window) ---' 'Cyan'
    Disable-WindowsAutoUpdate
    Write-BootstrapMsg '  Windows Update service disabled for AUOptions=1.' 'Green'

    # --- Suppress Windows popup notifications ---
    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Suppressing Windows popup notifications ---' 'Cyan'

    # Machine-wide: disable consumer cloud content / "Get even more out of Windows" nags
    $ccPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
    New-Item -Path $ccPath -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $ccPath -Name 'DisableWindowsConsumerFeatures' -Value 1 -Type DWord -Force

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
