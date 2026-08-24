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

    Before any of that, the script asserts the two hardware facts a unit's provisioning depends
    on and no software step can supply: 64 GB of RAM installed, and drive letter D: free. Both
    exist because the imdisk provider mounts D: as a 32 GB RAM-backed volatile ImDisk. The
    check runs FIRST, before the hostname prompt and before anything is changed, so a machine
    short on either stops with the box untouched. It is a hard failure; the only exemption is
    -VmTestRun (the 8 GB dev VM, which builds with -ImdiskMountType file).

    D: held by the bootstrap medium ITSELF is not a failure -- on a bare unit the USB takes D:,
    C: being the system disk -- and that drive is gone before provisioning ever mounts the
    index disk. At the END of a successful run the script ejects that medium if it is
    removable, and says so loudly: a drive left plugged in is picked up again on the next boot
    and takes D: back, so only unplugging it is durable.

    This script performs ALL first-time prep; there is no separate prepare step. After it
    completes successfully, the operator verifies the summary and reboots if prompted. The unit
    is then ready for provisioning (the prov server's provisioning loop picks it up
    once it is in unit-registry.json, or run client\onboard-mast-unit.ps1 on the unit).

    USB / DVD: copy client\bootstrap.cmd, bootstrap.ps1, mast-client-util.ps1 and
    the Npcap installer (client\assets\npcap-*.exe) together (or use the autounattend ISO,
    which bundles all four).
    Double-click bootstrap.cmd so Windows runs PowerShell (many PCs
    open .ps1 in Notepad by default). Or from an elevated PowerShell:
        cd <folder containing bootstrap.ps1>
        .\bootstrap.ps1 -MastHostName mast05

    If you omit -MastHostName, the script prompts interactively, defaulting to the current
    computer name on plain Enter (not valid with -NonInteractive).

.PARAMETER MastHostName
    Windows computer name for this unit (mast01 .. mast20). NetBIOS: 1-15 chars, letters/digits/hyphen.

.PARAMETER Site
    Site code (e.g. 'ns', 'wis') selecting the unit's configuration profile at provisioning
    time. The operator's explicit choice -- NEVER derived from the hostname; persisted to
    C:\ProgramData\MAST\site.txt for onboard-mast-unit.ps1 to record in the prov server's
    unit-registry.json. Prompted interactively if omitted (default: the previously
    persisted site.txt choice when present, else 'ns'); required with -NonInteractive.

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
    Also downgrades the hardware preflight (64 GB RAM, D: free) from a hard failure to a
    warning: the dev VM has 8 GB and mounts D: file-backed, so it can never satisfy the
    production requirement and is not meant to.

.PARAMETER SkipTrim
    Service short-names to leave alone when the non-essential / vendor service trim
    runs (Print Spooler, Windows Search, Intel LMS, ASUS / Intel GCC / Realtek
    helpers), e.g. -SkipTrim WSearch,Spooler. The trim is applied by default;
    -SkipTrim is the only way to exempt specific services. Service names vary by
    driver version, so each entry carries a display-name fallback; anything not
    found is just reported "not present". Idempotent; safe to re-run.
#>

# Runs from a .cmd on a bare machine, before any MAST tooling exists: the password
# arrives as a command-line string because there is no session to hold a
# SecureString, and New-LocalUser/Set-LocalUser require the conversion. Both
# findings are accepted, not oversights.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'MastPassword',
    Justification = 'Bootstrap is invoked from a .cmd on a machine with no MAST tooling; a SecureString cannot cross that boundary.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Set-LocalUser/New-LocalUser take a SecureString; the plaintext is the parameter above, which cannot be a SecureString here.')]
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
    [string[]]$SkipTrim = @(),
    # Re-assert already-provisioned units instead of bootstrapping a bare one.
    # Runs ONLY the elements the registry marks re-assertable, never prompts and
    # never reboots, so provisioning can converge the fleet without a USB stick
    # and without a person at the console (#143).
    [switch]$ReassertOnly,
    # Comma-separated element ids. Default (empty) is every 'routine' element.
    # An 'on-demand' element runs only when named here -- notably the two that
    # re-assert the transport the run may be travelling over.
    [string]$Elements = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Not optional: Disable-WindowsAutoUpdate and the hardware-preflight helpers below
# both come from here, and the first of them runs before anything else. Missing it
# used to surface as "term not recognized" a thousand lines in.
$_clientUtilDot = Join-Path $PSScriptRoot 'mast-client-util.ps1'
if (-not (Test-Path $_clientUtilDot)) {
    throw "mast-client-util.ps1 not found next to this script ($_clientUtilDot). Copy it alongside bootstrap.ps1 (the autounattend ISO bundles it)."
}
. $_clientUtilDot

$script:BootstrapLogDir = Join-Path $env:SystemDrive 'MAST\logs'
$script:BootstrapLog = Join-Path $script:BootstrapLogDir 'bootstrap.log'
$script:RebootRecommended = $false
$script:AllowUnencryptedOk = $false
# Set by the preflight when D: turned out to be the bootstrap medium itself, so the
# end of the run can say so again after the drive has been ejected.
$script:BootstrapMediaOnD = $false
$script:BootstrapMediaIsRemovable = $false
# Things this run was required to establish and did not. Appended to by any
# section that fails a hard requirement; drives the exit code and the end-of-run
# banner. A warning the operator scrolls past is how mast06 reported a clean run
# with no SSH server on it (#123).
$script:BootstrapBlockers = @()
$script:BootstrapMediaLetter = ''

# BIOS power policy: what the firmware check found, and whether a human saw it.
# Deliberately NOT a blocker -- provisioning cannot write BIOS setup, and a unit
# with a wrong power policy still needs to be built. The prompt below waits for
# an operator to acknowledge and then continues on its own, so an unattended or
# walked-away-from run is delayed, never stopped.
$script:BiosCheckFacts = $null
$script:BiosAckTimeoutSeconds = 120

# Bootstrap version: stamped to C:\MAST\bootstrap-manifest.json on success so the fleet
# drift report (tools/fleet-drift-report.py) can tell which bootstrap each unit ran and
# flag units missing newer bootstrap elements. BUMP THIS whenever you add a bootstrap
# capability, and add a matching element (since = this number) to
# client/bootstrap-elements.json so its current_version stays == this value.
$script:BootstrapVersion = 13

# --- Hardware requirement (asserted before anything is changed) ---------------
# Kept in step with server\lib\mast-modules.psm1 Get-MastRequiredMemoryGB, which is
# the fleet's single declaration of the figure. This script runs OFFLINE on a bare
# unit and cannot read that module, so it embeds the number -- the same situation
# as $knownSites below, and guarded the same way: build-mast.ps1 runs
# Assert-BootstrapMemoryRequirementInSync on every build and FAILS the build if the
# two drift.
$script:RequiredMemoryGB = 64
# Volume label imdisk formats the index disk with (provide-imdisk.ps1 -IndexSubdir).
# D: carrying THAT is the wanted end state, not a conflict -- bootstrap is
# idempotent and gets re-run on units that are already provisioned.
$script:IndexVolumeLabel = 'mast-indexes'

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

function Get-MastInstalledMemoryBanks {
    # Per-DIMM capacities, for the report only. Which slot is short is what an
    # operator needs to know once the total comes up wrong; it is deliberately
    # not what the check thresholds on (see Test-MastMemoryRequirement).
    # Some virtual firmware enumerates nothing here, so an empty result is a
    # missing diagnostic, never a verdict.
    try {
        return @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop |
            ForEach-Object { [math]::Round($_.Capacity / 1GB, 0) })
    } catch {
        return @()
    }
}

function Find-MastBootstrapMedia {
    # Record whether this script is running from a removable volume, so the end
    # of the run can tell the operator to unplug it.
    #
    # This used to eject the volume as well (mountvol /P). It no longer does:
    # cmd.exe reads a batch file incrementally, seeking back to its saved offset
    # for each line, so dismounting the volume out from under the running
    # bootstrap.cmd wrapper killed the wrapper mid-script -- the tail
    # never ran and the window closed with no error (#107).
    #
    # Nothing is lost by dropping it. The eject never survived a reboot anyway:
    # a drive left plugged in is re-enumerated on the next boot and takes its
    # letter back regardless. Only physically removing it is durable, which is
    # what the notice has always been for.
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { return }
    $root = [System.IO.Path]::GetPathRoot($PSScriptRoot)
    if ($root -notmatch '^[A-Za-z]:\\$') { return }
    $letter = $root.Substring(0, 2)

    $vol = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $letter) -ErrorAction SilentlyContinue
    # DriveType 2 = removable disk. A CD-ROM (5) is deliberately left alone: the
    # dev VM runs this from the autounattend ISO and there is nothing to unplug.
    if ($null -eq $vol -or [int]$vol.DriveType -ne 2) { return }

    $script:BootstrapMediaIsRemovable = $true
    $script:BootstrapMediaLetter = $letter
}

function Assert-MastUnitHardware {
    # The two facts provisioning cannot supply for itself. Runs before the
    # hostname prompt and before the first mutation, so a unit that fails here
    # is left exactly as it was found.
    param([switch]$IsVmTestRun)

    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Hardware preflight (RAM, drive D:) ---' 'Cyan'
    $problems = @()

    $visibleBytes = [long](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
    $mem = Test-MastMemoryRequirement -VisibleBytes $visibleBytes -RequiredGB $script:RequiredMemoryGB
    $banks = @(Get-MastInstalledMemoryBanks)
    $bankText = if ($banks.Count -gt 0) { ($banks | ForEach-Object { "${_} GB" }) -join ' + ' } else { '(not enumerated)' }
    Write-BootstrapMsg ("  Memory: {0} GB visible to Windows; banks: {1}; required {2} GB (floor {3} GB)." -f `
        $mem.VisibleGB, $bankText, $mem.RequiredGB, $mem.FloorGB) 'White'
    if ($mem.Ok) {
        Write-BootstrapMsg '  [OK] Memory requirement met.' 'Green'
    } else {
        $problems += ("this machine has {0} GB of RAM; a MAST unit needs {1} GB. Power down, fit the memory, and re-run." -f $mem.VisibleGB, $mem.RequiredGB)
    }

    $dDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='D:'" -ErrorAction SilentlyContinue
    $dPresent = ($null -ne $dDisk) -or (Test-Path -LiteralPath 'D:\')
    $dType = 0
    $dLabel = ''
    if ($dDisk) {
        $dType = [int]$dDisk.DriveType
        if ($dDisk.VolumeName) { $dLabel = [string]$dDisk.VolumeName }
    }
    $verdict = Get-MastDriveDVerdict -Present $dPresent -DriveType $dType -VolumeName $dLabel `
        -IndexVolumeLabel $script:IndexVolumeLabel -RunningFromD ($PSScriptRoot -like 'D:*')
    switch ($verdict) {
        'free' {
            Write-BootstrapMsg '  [OK] Drive letter D: is free for the index RAM disk.' 'Green'
        }
        'index' {
            Write-BootstrapMsg ("  [OK] D: already carries the '{0}' index volume (unit is provisioned)." -f $script:IndexVolumeLabel) 'Green'
        }
        'self' {
            # Not a defect: this is the stick in the operator's hand, and it is
            # gone long before the imdisk mount. The obligation it leaves is
            # repeated at the end of the run and in the desktop report.
            $script:BootstrapMediaOnD = $true
            Write-BootstrapMsg '  [OK] D: is this bootstrap medium, not a fitted disk; it frees up when the drive is removed.' 'Green'
        }
        'removable' {
            $problems += ("drive letter D: is a removable drive (label='{0}') and the index RAM disk requires it. If this is the bootstrap drive, eject it and re-run from a copy on C:; otherwise remove that device or reassign its letter." -f $dLabel)
        }
        'foreign' {
            $problems += ("drive letter D: is taken (DriveType={0} label='{1}'); the index RAM disk requires it. Remove the D: disk, or reassign that device's letter, and re-run." -f $dType, $dLabel)
        }
    }

    if ($problems.Count -eq 0) { return }
    foreach ($p in $problems) {
        Write-BootstrapMsg ("  [FAIL] {0}" -f $p) 'Red'
    }
    if ($IsVmTestRun) {
        Write-BootstrapMsg '  [WARN] -VmTestRun: continuing anyway. The dev VM cannot meet the production hardware requirement (build with -ImdiskMountType file).' 'Yellow'
        return
    }
    throw ("Hardware preflight failed: {0} Nothing has been changed on this machine." -f ($problems -join ' Also: '))
}

function Read-MastAcknowledgment {
    # Wait for an operator to press 'y', then continue -- but continue anyway
    # after $TimeoutSeconds. This is an attention-getter, not a gate: the fleet
    # will take boards that do not exist yet, so 'cannot verify this BIOS' will
    # be the NORMAL result on new hardware, and it must never be the reason a
    # unit failed to get built.
    #
    # Returns $true only if a human actually pressed y.
    param([int]$TimeoutSeconds = 120)

    # A redirected or non-console host has no RawUI keyboard; probing it throws.
    # There is nobody to acknowledge in that case, so do not pretend to ask.
    try { $null = $Host.UI.RawUI.KeyAvailable } catch { return $false }

    Write-BootstrapMsg ("  Press 'y' to acknowledge (continuing on its own in {0}s) ..." -f $TimeoutSeconds) 'Yellow'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($Host.UI.RawUI.KeyAvailable) {
            $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            if ($key.Character -eq 'y' -or $key.Character -eq 'Y') { return $true }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Show-MastFirmwarePowerPolicy {
    # Read the BIOS power policy and tell the operator about it -- at the one
    # moment in a unit's life when someone is standing at the machine and can
    # walk into BIOS setup and fix it.
    #
    # Never throws, never appends to $script:BootstrapBlockers. The whole point
    # is that this is the ONE check bootstrap makes that it cannot itself
    # remedy, so it informs rather than gates. What it does do is refuse to be
    # silent: the result is printed here, repeated in the desktop report, and
    # stamped into bootstrap-manifest.json with whether a human acknowledged it.
    param([switch]$IsNonInteractive)

    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- BIOS power policy (read-only; provisioning cannot change this) ---' 'Cyan'

    $lib = Join-Path $PSScriptRoot 'mast-firmware.ps1'
    if (-not (Test-Path -LiteralPath $lib)) { $lib = Join-Path $PSScriptRoot '..\server\lib\mast-firmware.ps1' }
    if (-not (Test-Path -LiteralPath $lib)) {
        Write-BootstrapMsg '  [WARN] mast-firmware.ps1 is not on this medium; BIOS power policy not checked.' 'Yellow'
        $script:BiosCheckFacts = [ordered]@{ status = 'not-run'; reason = 'mast-firmware.ps1 missing' }
        return
    }

    try {
        . $lib
        $state = Get-MastFirmwarePolicyState -ScriptRoot $PSScriptRoot
    } catch {
        Write-BootstrapMsg ("  [WARN] BIOS power policy check errored: {0}" -f $_.Exception.Message) 'Yellow'
        $script:BiosCheckFacts = [ordered]@{ status = 'error'; reason = $_.Exception.Message }
        return
    }

    Write-BootstrapMsg ("  Board: {0}   BIOS: {1}" -f `
        $(if ($state.BaseboardProduct) { $state.BaseboardProduct } else { '(unknown)' }),
        $(if ($state.BiosVersion) { $state.BiosVersion } else { '(unknown)' })) 'White'
    foreach ($f in @($state.Fields)) {
        $mark = if ($f.Ok) { '[OK]  ' } else { '[WARN]' }
        $color = if ($f.Ok) { 'Green' } else { 'Red' }
        Write-BootstrapMsg ("  {0} {1} = {2} (expected {3})" -f $mark, $f.Name, $f.Actual, $f.Expect) $color
    }

    $acknowledged = $false
    $ackReason = ''
    switch ($state.Status) {
        'match' {
            Write-BootstrapMsg '  [OK] BIOS power policy matches the known-good baseline for this board.' 'Green'
        }
        'unavailable' {
            # The dev VM and any non-UEFI/non-AMI box land here. Nothing to
            # acknowledge and nobody to ask -- say so once and move on, or every
            # VM bootstrap cycle would sit here waiting for a keypress.
            foreach ($m in @($state.Messages)) { Write-BootstrapMsg ("  [WARN] {0}" -f $m) 'Yellow' }
        }
        default {
            foreach ($m in @($state.Messages)) { Write-BootstrapMsg ("  [WARN] {0}" -f $m) 'Yellow' }
            if ($state.NeedsAttention) {
                Write-BootstrapMsg '' 'Red'
                Write-BootstrapMsg '  ****************************************************************' 'Red'
                Write-BootstrapMsg '  *  THIS UNIT MAY NOT POWER ITSELF BACK ON AFTER A MAINS EVENT  *' 'Red'
                Write-BootstrapMsg '  ****************************************************************' 'Red'
                Write-BootstrapMsg '  Fix it now while you are at the machine: reboot, enter BIOS setup (Del),' 'Yellow'
                Write-BootstrapMsg '  Advanced -> APM Configuration -> Restore AC Power Loss = S0 State, F10.' 'Yellow'
                Write-BootstrapMsg '  Bootstrap continues either way -- this is a warning, not a blocker.' 'Yellow'
                if ($IsNonInteractive) {
                    $ackReason = 'non-interactive'
                    Write-BootstrapMsg '  (-NonInteractive: not prompting; recorded as unacknowledged.)' 'DarkGray'
                } else {
                    $acknowledged = Read-MastAcknowledgment -TimeoutSeconds $script:BiosAckTimeoutSeconds
                    if ($acknowledged) {
                        $ackReason = 'operator'
                        Write-BootstrapMsg '  Acknowledged. Continuing.' 'White'
                    } else {
                        $ackReason = 'timeout'
                        Write-BootstrapMsg '  No acknowledgment; continuing anyway (recorded).' 'DarkGray'
                    }
                }
            }
        }
    }

    $facts = [ordered]@{
        status           = [string]$state.Status
        baseboard        = [string]$state.BaseboardProduct
        bios_version     = [string]$state.BiosVersion
        setup_sha256     = [string]$state.Sha256
        baseline_matched = [bool]$state.BaselineMatched
        needs_attention  = [bool]$state.NeedsAttention
        acknowledged     = [bool]$acknowledged
    }
    if ($ackReason) { $facts['acknowledgment'] = $ackReason }
    foreach ($f in @($state.Fields)) {
        $facts[('field_' + ($f.Name -replace '[^A-Za-z0-9]+', '_').ToLowerInvariant())] = [int]$f.Actual
    }
    $script:BiosCheckFacts = $facts
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
        try { $null = cmd.exe /c 'ipconfig /renew' 2>&1 } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
    }
}

function Initialize-MastWinRmFirewallRule5985 {
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
# AUTO-GENERATED by bootstrap.ps1. Re-assert all network connection
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
    try { $startup.Delay = 'PT20S' } catch { Write-Verbose "ignored: $($_.Exception.Message)" }   # let NLA settle before re-asserting
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
    try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
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

function Write-BootstrapDesktopReport([string]$HostNm, [string]$SiteCode) {
    # Post-bootstrap operator report on the all-users desktop: what this machine
    # is, its MACs (for site DHCP reservations), and the manual steps bootstrap
    # cannot do itself (BIOS power policy, provisioning handoff). Plus a
    # shortcut to the installation directory.
    $desktop = 'C:\Users\Public\Desktop'
    if (-not (Test-Path $desktop)) { New-Item -ItemType Directory -Path $desktop -Force | Out-Null }
    # On a provisioned machine the desktop is organized under Desktop\MAST
    # (desktop-shortcuts provider); a bootstrap RE-run must not litter the
    # root again -- write into Setup and Calibration when it exists.
    $targetDir = $desktop
    $setupDir = Join-Path $desktop 'MAST\Setup and Calibration'
    if (Test-Path -LiteralPath $setupDir) { $targetDir = $setupDir }
    $lines = @(
        '================= MAST unit bootstrap report =================',
        ('generated : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ('hostname  : {0}' -f $HostNm),
        ('site      : {0}' -f $SiteCode),
        ('bootstrap : version {0}' -f $script:BootstrapVersion),
        ''
        '--- Hardware (asserted at bootstrap) ---'
    )
    try {
        $visible = [long](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
        $banks = @(Get-MastInstalledMemoryBanks)
        $lines += ('  memory : {0:N1} GB visible, required {1} GB   banks: {2}' -f `
            ($visible / 1GB), $script:RequiredMemoryGB,
            $(if ($banks.Count -gt 0) { ($banks | ForEach-Object { "${_} GB" }) -join ' + ' } else { '(not enumerated)' }))
    } catch { $lines += ('  memory : (query failed: {0})' -f $_.Exception.Message) }
    $dLd = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='D:'" -ErrorAction SilentlyContinue
    $lines += ('  drive D: {0}' -f $(
        if ($script:BootstrapMediaOnD) { 'held by the bootstrap drive only - free once that drive is removed' }
        elseif ($dLd) { ("in use (DriveType={0} label='{1}')" -f $dLd.DriveType, $dLd.VolumeName) }
        else { 'free (reserved for the index RAM disk)' }))
    if ($script:BootstrapMediaOnD) {
        $lines += '           D: MUST be free for the index RAM disk before this unit provisions.'
    }
    $lines += @(
        ''
        '--- Network adapters (record MACs for DHCP reservations) ---'
    )
    try {
        foreach ($a in @(Get-NetAdapter -Physical -ErrorAction Stop | Sort-Object ifIndex)) {
            $ip = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
            $lines += ('  {0,-12} {1,-17} {2,-12} ip={3,-15} ({4})' -f $a.Name, $a.MacAddress, $a.Status, $(if ($ip) { $ip } else { '-' }), $a.InterfaceDescription)
        }
    } catch { $lines += ('  (adapter query failed: {0})' -f $_.Exception.Message) }
    $lines += @(
        '',
        '--- BIOS power policy (checked at bootstrap; fixed by hand) ---',
        'The unit must power back on by itself when mains power returns (the DLI',
        'switch cuts and restores AC). In BIOS/UEFI setup:',
        '  * Advanced -> APM Configuration -> "Restore AC Power Loss" = S0 State',
        '    (ASUS wording; other boards call it "AC Power Recovery" or "After',
        '    Power Loss" -- set Power On, NOT Last State).',
        '  * Disable "ErP Ready" / deep-sleep options if present (they can block',
        '    power-on-after-mains).',
        'Provisioning can READ this setting but cannot change it, so it is always',
        'a manual fix. What this bootstrap measured:'
    )
    if ($script:BiosCheckFacts) {
        $lines += ('  status : {0}{1}' -f $script:BiosCheckFacts['status'], $(
            if ($script:BiosCheckFacts['acknowledgment']) { " (acknowledged: $($script:BiosCheckFacts['acknowledgment']))" } else { '' }))
        foreach ($k in $script:BiosCheckFacts.Keys) {
            if ($k -like 'field_*') { $lines += ('  {0,-22} = {1}' -f $k, $script:BiosCheckFacts[$k]) }
        }
        if ($script:BiosCheckFacts['status'] -ne 'match') {
            $lines += '  ACTION: verify the setting above in BIOS setup before this unit ships.'
        }
    } else {
        $lines += '  (not measured on this run)'
    }
    $lines += @(
        '',
        '--- NEXT: provisioning handoff ---',
        ('1) Ensure the prov server resolves {0} (DNS or hosts entry).' -f $HostNm),
        ('2) Register {0} (hostname + site) in server\unit-registry.json on the' -f $HostNm),
        '   prov server and run the provisioning driver; or run',
        ('   onboard-mast-unit.ps1 -HostName {0} -ProvServer <prov-ip> on this unit.' -f $HostNm),
        '3) After provisioning + hardware hookup: run the "MAST Instrument',
        '   Calibration" desktop shortcut to bind instrument COM ports.',
        '',
        ('Logs: {0} ; provisioning logs land under {1}.' -f $script:BootstrapLog, $script:BootstrapLogDir)
    )
    $reportPath = Join-Path $targetDir 'MAST Bootstrap Report.txt'
    Set-Content -LiteralPath $reportPath -Value $lines -Encoding UTF8
    Write-BootstrapMsg ("  Desktop report written: {0}" -f $reportPath) 'White'
    try {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut((Join-Path $targetDir 'MAST Installation Directory.lnk'))
        $lnk.TargetPath = 'C:\MAST'
        $lnk.Description = 'MAST installation directory (repos, logs, staging)'
        $lnk.Save()
        Write-BootstrapMsg '  Desktop shortcut written: MAST Installation Directory -> C:\MAST' 'White'
    } catch {
        Write-BootstrapMsg ("  [WARN] could not create C:\MAST desktop shortcut: {0}" -f $_.Exception.Message) 'Yellow'
    }
}

# Set the machine-wide ExecutionPolicy here rather than printing it as a manual step.
# It was printed for months and skipped on mast04 (2026-07-07) and mast03
# (2026-07-08), then applied by hand both times -- #51. Bootstrap already runs
# elevated, so there was never a capability reason for it to be manual.
#
# Set-ExecutionPolicy writes the registry and THEN throws SecurityException with
# FullyQualifiedErrorId 'ExecutionPolicyOverride' if a more permissive scope shadows
# the one written (measured on mast03, PS 5.1.19041.4522). Bootstrap is normally run
# from an interactive console where nothing shadows it, but it can be launched with
# -ExecutionPolicy Bypass, so the read-back -- not the absence of a throw -- is what
# decides. The execution-policy provider re-asserts this on every cycle; bootstrap
# is the one-shot that stops a fresh unit shipping Restricted in the meantime.
function Set-MastExecutionPolicy {
    $want = 'RemoteSigned'
    $before = (Get-ExecutionPolicy -Scope LocalMachine).ToString()
    if ($before -eq $want) {
        Write-BootstrapMsg ("  ExecutionPolicy LocalMachine already {0}." -f $want) 'White'
        return
    }
    try {
        Set-ExecutionPolicy -ExecutionPolicy $want -Scope LocalMachine -Force -ErrorAction Stop
    } catch [System.Security.SecurityException] {
        if ($_.FullyQualifiedErrorId -notlike 'ExecutionPolicyOverride*') {
            Write-BootstrapMsg ("  [WARN] Set-ExecutionPolicy: {0}" -f $_.Exception.Message) 'Yellow'
        }
    } catch {
        Write-BootstrapMsg ("  [WARN] Set-ExecutionPolicy failed: {0}" -f $_.Exception.Message) 'Yellow'
    }
    $after = (Get-ExecutionPolicy -Scope LocalMachine).ToString()
    if ($after -eq $want) {
        Write-BootstrapMsg ("  ExecutionPolicy LocalMachine set to {0} (was {1})." -f $after, $before) 'White'
        return
    }
    $gpo = @(Get-ExecutionPolicy -List |
        Where-Object { $_.Scope -in @('MachinePolicy', 'UserPolicy') -and $_.ExecutionPolicy -ne 'Undefined' })
    if ($gpo.Count -gt 0) {
        $which = ($gpo | ForEach-Object { "{0}={1}" -f $_.Scope, $_.ExecutionPolicy }) -join ', '
        Write-BootstrapMsg ("  [WARN] ExecutionPolicy is {0}, wanted {1}; Group Policy defines {2} and outranks LocalMachine." -f $after, $want, $which) 'Yellow'
        Write-BootstrapMsg '         This needs a domain-policy change; provisioning cannot fix it.' 'Yellow'
    } else {
        Write-BootstrapMsg ("  [WARN] ExecutionPolicy is {0}, wanted {1}, with no Group Policy to explain it." -f $after, $want) 'Yellow'
    }
}

function Show-BootstrapNextSteps([string]$HostNm) {
    Write-BootstrapMsg '' 'Green'
    Write-BootstrapMsg '--- NEXT: hand off to provisioning ---' 'Green'
    Write-BootstrapMsg '  Bootstrap has done all first-time prep (mast admin, WinRM HTTP/5985, firewall,' 'Green'
    Write-BootstrapMsg '  OpenSSH, Npcap, Windows Update suppression, computer name, ExecutionPolicy).' 'Green'
    Write-BootstrapMsg '  No prepare step remains.' 'Green'
    Write-BootstrapMsg "  1) Ensure the prov server resolves $HostNm (DNS or hosts entry)." 'Green'
    Write-BootstrapMsg "  2) Add $HostNm to server\unit-registry.json on the prov server; the autonomous" 'Green'
    Write-BootstrapMsg '     provisioning loop will provision it on its next cycle.' 'Green'
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
        # when NTP is reachable -- resync + wait + check. ONE attempt only: on
        # NTP-less networks (the common bootstrap case) each attempt costs ~18 s
        # and the HTTP Date-header fallback below does the real work; the
        # provisioning timesync provider keeps its own retries for the tiered
        # one-time correction.
        $source = ''
        $lastSync = ''
        $synced = $false
        for ($attempt = 1; $attempt -le 1 -and -not $synced; $attempt++) {
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
                Write-BootstrapMsg ("  resync did not lock (Source='{0}'); falling back to web time." -f $source) 'DarkGray'
            }
        }
        if ($synced) {
            Write-BootstrapMsg ("  Time synced. Source={0}; clock now {1}." -f $source, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) 'Green'
        } else {
            # NTP genuinely unreachable: the Weizmann peers are campus-only and many
            # guest/home networks block outbound UDP 123 wholesale, so even the
            # public peers get no reply. Fall back to the Date header of a plain
            # HTTP probe -- works wherever TCP 80 works, is immune to the
            # broken-clock TLS trap (no certificate validation), and is accurate
            # to ~1-2 s, plenty to unbreak TLS validation.
            # ALL math in UTC. Comparing in local time bit us on mast01: the
            # same-run tzutil DST flip left this process's cached UTC offset
            # stale, ToLocalTime() produced a web time 1 h low, and the
            # fallback "corrected" a correct clock backwards by an hour.
            # UtcNow and Set-Date -Adjust never consult the local offset.
            $webUtc = $null
            foreach ($probeUrl in @('http://www.google.com', 'http://www.msftconnecttest.com/connecttest.txt')) {
                try {
                    $resp = Invoke-WebRequest -Uri $probeUrl -Method Head -UseBasicParsing -TimeoutSec 10
                    $dateHeader = $resp.Headers['Date']
                    if ($dateHeader) {
                        $webUtc = [DateTime]::ParseExact($dateHeader, 'R', [System.Globalization.CultureInfo]::InvariantCulture, ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal))
                        break
                    }
                } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
            }
            if ($webUtc) {
                $delta = $webUtc - [DateTime]::UtcNow
                $skewSeconds = [Math]::Abs($delta.TotalSeconds)
                if ($skewSeconds -gt 30) {
                    Set-Date -Adjust $delta | Out-Null
                    Write-BootstrapMsg ("  NTP unreachable; clock adjusted {0:N0}s from an HTTP Date header (UTC now {1})." -f $delta.TotalSeconds, [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) 'Green'
                    Write-BootstrapMsg '  w32time stays configured; it will refine the clock when NTP becomes reachable (e.g. on the site network).' 'White'
                } else {
                    Write-BootstrapMsg ("  NTP unreachable, but the clock is already within {0:N1}s of web time (UTC-compared) -- fine for TLS; left as-is." -f $skewSeconds) 'Green'
                }
            } else {
                Write-BootstrapMsg '  [WARN] NTP did NOT actually sync -- the time service is still on the local clock.' 'Yellow'
                Write-BootstrapMsg ("         Source='{0}' LastSuccessfulSync='{1}'. UDP 123 is likely blocked or there is no route to the NTP servers," -f $source, $lastSync) 'Yellow'
                Write-BootstrapMsg '         and the HTTP Date-header fallback got no response either (no outbound TCP 80?).' 'Yellow'
                Write-BootstrapMsg '         A wrong clock breaks TLS validation, so the provisioning git clone (HTTPS) will fail.' 'Yellow'
                Write-BootstrapMsg '         FIX one of: open outbound UDP 123; point w32time at a reachable NTP source' 'Yellow'
                Write-BootstrapMsg '         (e.g. the prov server: w32tm /config /manualpeerlist:"<provIP>" /syncfromflags:manual /update; w32tm /resync); or set the clock manually.' 'Yellow'
            }
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

# --- Bootstrap elements: the re-assertable ones, addressable by id -----------
#
# One function per element of client/bootstrap-elements.json, each holding
# exactly the code that used to sit inline in the main flow -- moved, not
# rewritten. The main flow calls them by id through the map below, so the SAME
# code can be re-run on an already-provisioned unit without re-running the
# whole script (#143).
#
# Only elements the registry marks 'routine' or 'on-demand' are here: those are
# the ones that must be individually invocable. 'console' elements (the account,
# autologon, rename, Npcap, the preflight, media handling) are first touch only
# and stay inline; 'provider' elements are re-asserted by a provisioning
# provider, not by re-running bootstrap's copy. build-mast.ps1 fails the build
# if this map and the registry disagree.

function Invoke-MastBootstrapElementTimezoneIsraelDst {
    Write-BootstrapMsg '--- Time zone (Israel Standard Time, auto-DST) ---' 'Cyan'
    try {
        ${tzKey} = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
        ${tzBefore} = (Get-TimeZone).Id
        ${dstWasOff} = ((Get-ItemProperty -Path ${tzKey} -Name DynamicDaylightTimeDisabled -ErrorAction SilentlyContinue).DynamicDaylightTimeDisabled -eq 1)
        if (${tzBefore} -ne 'Israel Standard Time' -or ${dstWasOff}) {
            & tzutil.exe /s 'Israel Standard Time'
            if (${LASTEXITCODE} -ne 0) { throw ("tzutil /s exited {0}" -f ${LASTEXITCODE}) }
            # Drop this process's cached UTC offset so local-time math and log
            # timestamps later in this same run see the new DST state.
            [TimeZoneInfo]::ClearCachedData()
            Write-BootstrapMsg ("  Time zone set to Israel Standard Time (was '{0}'; auto-DST was {1}); local time now {2}." -f `
                ${tzBefore}, $(if (${dstWasOff}) { 'OFF' } else { 'on' }), (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) 'Green'
        } else {
            Write-BootstrapMsg '  Time zone already Israel Standard Time with auto-DST on.' 'Green'
        }
    } catch {
        Write-BootstrapMsg ("  [WARN] time zone setup failed: {0}" -f $_.Exception.Message) 'Yellow'
    }

    # --- Sync system time with public NTP (before anything TLS-sensitive) ---
}

function Invoke-MastBootstrapElementWindowsUpdateSuppress {
    Write-BootstrapMsg '--- Suppressing Windows Update (provisioning window) ---' 'Cyan'
    Disable-WindowsAutoUpdate
    Write-BootstrapMsg '  Windows Update service disabled for AUOptions=1.' 'Green'

    # --- Suppress Windows popup notifications ---
}

function Invoke-MastBootstrapElementPopupNotificationSuppress {
    Write-BootstrapMsg '--- Suppressing Windows popup notifications ---' 'Cyan'

    # MACHINE-WIDE ONLY. Consumer cloud content ("Get even more out of Windows" nags)
    # is disabled in the telemetry/privacy hardening table below
    # (DisableWindowsConsumerFeatures); what is left here is the backup-reminder task.
    #
    # The per-user (HKCU) toast and content-delivery suppressions used to live here and
    # moved to the desktop-appearance provider in #106. They could not work from here:
    # the mast account is created a few dozen lines above this point and has never
    # logged on, so it has no profile and no hive -- the writes landed in the hive of
    # whoever ran bootstrap, and reported success. Provisioning runs after a profile
    # exists, and owns every other per-user desktop value already.

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
        } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
    }

    Write-BootstrapMsg '  Backup-reminder tasks disabled (per-user quieting moved to provisioning, #106).' 'Green'

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
}

function Invoke-MastBootstrapElementLocaleEnUs {
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
    } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
    if (-not ($intlHiveTargets | Where-Object { $_.Key -eq 'MAST_INTL_MAST' })) {
        Write-BootstrapMsg "  mast profile not created yet; it will inherit en-US from the Default-user template at first login." 'DarkGray'
    }

    foreach ($h in $intlHiveTargets) {
        $loaded = $false
        try {
            & reg.exe load ("HKU\{0}" -f $h.Key) $h.Dat 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $loaded = $true }
        } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
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
            try { & reg.exe unload ("HKU\{0}" -f $h.Key) 2>&1 | Out-Null } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
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
}

function Invoke-MastBootstrapElementTelemetryPrivacyHarden {
    Write-BootstrapMsg '--- Hardening: telemetry / privacy ---' 'Cyan'

    $dataCollection = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
    $cloudContent   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
    $sys            = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    $search         = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
    $appPrivacy     = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
    $inputPersonal  = 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization'

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
        # Suppresses the "Choose privacy settings for your device" page at first
        # console logon (matters here: autologon means nobody is at the console to
        # click through it). The per-toggle policies below force the same answers.
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'; Name = 'DisablePrivacyExperience'; Value = 1; Desc = 'No first-logon privacy settings page' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'; Name = 'DisableLocation'; Value = 1; Desc = 'Location service off' }
        @{ Path = $inputPersonal;  Name = 'AllowInputPersonalization';      Value = 0; Desc = 'Inking/typing personalization off' }
        @{ Path = $inputPersonal;  Name = 'RestrictImplicitInkCollection';  Value = 1; Desc = 'No implicit ink collection' }
        @{ Path = $inputPersonal;  Name = 'RestrictImplicitTextCollection'; Value = 1; Desc = 'No implicit text collection' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\TextInput'; Name = 'AllowLinguisticDataCollection'; Value = 0; Desc = 'No typing linguistic data upload' }
        @{ Path = $cloudContent;   Name = 'DisableTailoredExperiencesWithDiagnosticData'; Value = 1; Desc = 'Tailored experiences off' }
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
}

function Invoke-MastBootstrapElementServiceTrim {
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
}

function Invoke-MastBootstrapElementDhcpIpv4 {
    Write-BootstrapMsg '--- Network: ensure DHCP for IPv4 ---' 'Cyan'
    Set-MastAdaptersToDhcp

    # --- WinRM ---
}

function Invoke-MastBootstrapElementWinrmHttpBasic {
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
            } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
        }
    } catch {
        Write-BootstrapMsg ("  WARN: per-adapter profile: {0}" -f $_.Exception.Message) 'Yellow'
    }
    $nlProfiles = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles'
    if (Test-Path $nlProfiles) {
        Get-ChildItem $nlProfiles -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Set-ItemProperty -LiteralPath $_.PSPath -Name 'Category' -Value 1 -Type DWord -Force -ErrorAction Stop
            } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
        }
        Write-BootstrapMsg '  Registry fallback: NetworkList Profiles Category=Private where possible.' 'DarkGray'
    }
    try {
        Restart-Service nlasvc -Force -ErrorAction Stop
        Start-Sleep -Seconds 3
    } catch { Write-Verbose "ignored: $($_.Exception.Message)" }

    # Re-run idempotency: Enable-PSRemoting (via its internal
    # Set-WSManQuickConfig) can fail on an already-configured machine, and the
    # local WSMan CLIENT stack can be broken independently of the service --
    # mast01: a CIDR entry in the WinHTTP proxy bypass made every local WSMan
    # client call (Test-WSMan included) fault 87 while remote WinRM worked
    # fine. So: health-check via raw TCP (not Test-WSMan), log the outcome
    # either way, and treat an Enable-PSRemoting failure as a WARN -- the
    # authoritative gate is the 5985 verification at the end of this script.
    $winrmAlready = $false
    try {
        if ((Get-Service WinRM -ErrorAction Stop).Status -eq 'Running') {
            $tcpProbe = New-Object System.Net.Sockets.TcpClient
            try {
                $winrmAlready = $tcpProbe.ConnectAsync('127.0.0.1', 5985).Wait(3000)
            } finally { $tcpProbe.Close() }
        }
    } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
    if ($winrmAlready) {
        Write-BootstrapMsg '  WinRM service running and port 5985 answering; skipping Enable-PSRemoting.' 'Green'
    } else {
        Write-BootstrapMsg '  WinRM not yet serving on 5985; running Enable-PSRemoting...' 'DarkGray'
        try {
            Enable-PSRemoting -Force -SkipNetworkProfileCheck
        } catch {
            Write-BootstrapMsg ("  WARN: Enable-PSRemoting failed ({0}); continuing -- the final 5985 verification decides." -f $_.Exception.Message) 'Yellow'
        }
    }
    Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true -Force
    try {
        Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true -Force
        $script:AllowUnencryptedOk = $true
    } catch {
        Write-BootstrapMsg ("  WARN: AllowUnencrypted not set: {0}" -f $_.Exception.Message) 'Yellow'
        try { Restart-Service nlasvc -Force; Start-Sleep -Seconds 4 } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
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
    Initialize-MastWinRmFirewallRule5985 -RuleDisplayName 'MAST - WinRM HTTP'

    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Persist Private network profile across reboots ---' 'Cyan'
    try {
        Install-MastNetworkPrivateTask
    } catch {
        Write-BootstrapMsg ("  WARN: could not register MAST-NetworkPrivate task: {0}" -f $_.Exception.Message) 'Yellow'
        Write-BootstrapMsg '  Network may regress to Public after reboot; WinRM Basic could return 401 until re-run.' 'Yellow'
    }

    # --- OpenSSH Server (MSI + service + firewall + password auth) ---
    #
    # Installs Win32-OpenSSH from the bundled MSI and makes it operational.
    # Owned by bootstrap (not by the openssh-server provider) because the
    # provider cannot be reached before SSH exists, and because the in-box
    # OpenSSH.Server capability is rejected by DISM/CBS under the WinRM
    # network logon the provider pipeline uses even for a full admin. See
    # compare-mastw/GAPS.md + the 2026-05-25 DECISIONS entry.
    #
    # Steps:
    #   1. msiexec the bundled OpenSSH MSI (skipped when sshd is registered)
    #   2. Set sshd Automatic, Start-Service
    #   3. Same for ssh-agent (helpful, not strictly required)
    #   4. Firewall: inbound TCP 22 (using the same helper as 5985)
    #   5. sshd_config: assert PasswordAuthentication yes (matches mastw's
    #      working entry point of mast / physics over SSH)
    #
    # 1 was Add-WindowsCapability until #123; steps 2, 4 and 5 now record a
    # blocker rather than a warning when they cannot complete.
}

function Invoke-MastBootstrapElementOpensshFromMsi {
    Write-BootstrapMsg '--- OpenSSH Server ---' 'Cyan'
    # Installed from the bundled Win32-OpenSSH MSI, not from the OpenSSH.Server
    # Features-on-Demand capability. The capability needs a servicing payload
    # fetched from Windows Update or matched to the running build, and it
    # registers sshd asynchronously: on mast06 Add-WindowsCapability reported
    # success after 4m33s with sshd still unregistered a moment later, so the
    # service was never configured and the run still exited 0 (#123). msiexec
    # returns only once the service exists, so there is nothing to wait out, and
    # the MSI is one binary for every build -- unlike the per-build cabs #124
    # had to introduce for NetFx3.
    $sshMsi = Join-Path $PSScriptRoot 'OpenSSH-Win64-v10.0.0.0.msi'
    if (Get-Service -Name 'sshd' -ErrorAction SilentlyContinue) {
        Write-BootstrapMsg '  sshd already registered; skipping the OpenSSH install.' 'DarkGray'
    } elseif (-not (Test-Path -LiteralPath $sshMsi)) {
        $msg = "OpenSSH MSI missing from the bootstrap media at ${sshMsi}"
        $script:BootstrapBlockers += $msg
        Write-BootstrapMsg ("  [BLOCKER] {0}" -f $msg) 'Red'
        Write-BootstrapMsg '  Restage the bootstrap media; SSH is how provisioning reaches this unit.' 'Red'
    } else {
        Write-BootstrapMsg ("  Installing Win32-OpenSSH from {0}..." -f (Split-Path $sshMsi -Leaf)) 'White'
        try {
            $mp = Start-Process -FilePath 'msiexec.exe' `
                -ArgumentList @('/i', ('"{0}"' -f $sshMsi), '/qn', '/norestart') `
                -PassThru -Wait -WindowStyle Hidden
            if ($mp.ExitCode -ne 0 -and $mp.ExitCode -ne 3010) {
                throw ("msiexec exit {0}" -f $mp.ExitCode)
            }
            if ($null -eq (Get-Service -Name 'sshd' -ErrorAction SilentlyContinue)) {
                throw 'msiexec reported success but sshd is still not registered'
            }
            Write-BootstrapMsg '  Win32-OpenSSH installed (sshd registered).' 'Green'
        } catch {
            $msg = "OpenSSH install failed: $($_.Exception.Message)"
            $script:BootstrapBlockers += $msg
            Write-BootstrapMsg ("  [BLOCKER] {0}" -f $msg) 'Red'
        }
    }

    foreach ($svc in @('sshd', 'ssh-agent')) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($null -eq $s) {
            if ($svc -eq 'sshd') {
                $msg = "service 'sshd' is not registered, so it was never set Automatic or started"
                $script:BootstrapBlockers += $msg
                Write-BootstrapMsg ("  [BLOCKER] {0}" -f $msg) 'Red'
            } else {
                Write-BootstrapMsg ("  Service '{0}' not registered; skipping (not required)." -f $svc) 'Yellow'
            }
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
        $msg = "sshd_config not found at ${sshdCfg}, so PasswordAuthentication was never asserted"
        $script:BootstrapBlockers += $msg
        Write-BootstrapMsg ("  [BLOCKER] {0}" -f $msg) 'Red'
    }

    # --- Windows Firewall: disable (perimeter-protected fleet) ---
    #
    # MAST units sit on an isolated VLAN behind a perimeter firewall and need open
    # intra-fleet traffic (COM/RPC, Prometheus scraping, the control stack), so the
    # host Windows Firewall is turned off on all three profiles. The explicit
    # 5985 (WinRM) and 22 (SSH) inbound rules added above are kept deliberately:
    # they are harmless while the firewall is off and keep both services reachable
    # immediately if the firewall is ever re-enabled. See DECISIONS.md.
}

function Invoke-MastBootstrapElementFirewallOff {
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
}

# Each entry carries the element's reassert KIND as well as its function.
# bootstrap runs offline from removable media and cannot read
# client/bootstrap-elements.json, so it embeds the classification -- the same
# constraint $knownSites and $script:RequiredMemoryGB have, resolved the same
# way: build-mast.ps1 fails the build if the embedded kind and the registry
# disagree. Only 'routine' and 'on-demand' can appear here at all.
$script:MastBootstrapElementActions = [ordered]@{
    'timezone-israel-dst' = @{ Kind = 'routine'; Function = 'Invoke-MastBootstrapElementTimezoneIsraelDst' }
    'windows-update-suppress' = @{ Kind = 'routine'; Function = 'Invoke-MastBootstrapElementWindowsUpdateSuppress' }
    'popup-notification-suppress' = @{ Kind = 'routine'; Function = 'Invoke-MastBootstrapElementPopupNotificationSuppress' }
    'locale-en-us' = @{ Kind = 'routine'; Function = 'Invoke-MastBootstrapElementLocaleEnUs' }
    'telemetry-privacy-harden' = @{ Kind = 'routine'; Function = 'Invoke-MastBootstrapElementTelemetryPrivacyHarden' }
    'service-trim' = @{ Kind = 'routine'; Function = 'Invoke-MastBootstrapElementServiceTrim' }
    'dhcp-ipv4' = @{ Kind = 'routine'; Function = 'Invoke-MastBootstrapElementDhcpIpv4' }
    'winrm-http-basic' = @{ Kind = 'on-demand'; Function = 'Invoke-MastBootstrapElementWinrmHttpBasic' }
    'openssh-from-msi' = @{ Kind = 'on-demand'; Function = 'Invoke-MastBootstrapElementOpensshFromMsi' }
    'firewall-off' = @{ Kind = 'routine'; Function = 'Invoke-MastBootstrapElementFirewallOff' }
}

function Invoke-MastBootstrapElement {
    # Run one registered bootstrap element by id.
    param([Parameter(Mandatory)][string]$Id)
    if (-not $script:MastBootstrapElementActions.Contains($Id)) {
        throw ("unknown bootstrap element '{0}'" -f $Id)
    }
    & $script:MastBootstrapElementActions[$Id].Function
}

function Get-MastReassertSelection {
    <#
    .SYNOPSIS
      Which elements a -ReassertOnly run should apply, or the reason it cannot.
    .DESCRIPTION
      Pure decision, separated from the running so it is testable. Returns an
      object with Ids and Problems; a non-empty Problems means run nothing.

      An unrunnable request is an ERROR, never a silent skip. Asking for a
      console element and getting a quiet no-op would let an operator believe a
      unit had been brought up to date when the very element they named was the
      one that did not run.
    #>
    [CmdletBinding()]
    param([string]$Requested = '')

    $problems = @()
    $ids = @()
    $known = $script:MastBootstrapElementActions

    if ([string]::IsNullOrWhiteSpace($Requested)) {
        foreach ($k in $known.Keys) {
            if ($known[$k].Kind -eq 'routine') { $ids += $k }
        }
        return [pscustomobject]@{ Ids = $ids; Problems = $problems }
    }

    foreach ($raw in ($Requested -split ',')) {
        $id = $raw.Trim()
        if (-not $id) { continue }
        if (-not $known.Contains($id)) {
            $problems += ("'{0}' is not a re-assertable element. Re-assertable: {1}" -f $id, (($known.Keys) -join ', '))
            continue
        }
        if ($ids -contains $id) { continue }
        $ids += $id
    }
    return [pscustomobject]@{ Ids = $ids; Problems = $problems }
}

function Invoke-MastBootstrapReassert {
    <#
    .SYNOPSIS
      Re-apply the re-assertable elements on an already-provisioned unit.
    .DESCRIPTION
      Deliberately does NOT do any of bootstrap's first-touch work: no hardware
      preflight (it throws by design, and asserts a FREE D: that a provisioned
      unit has legitimately filled with the index volume), no prompts, no
      account or autologon, no rename, no Npcap, no reboot, no media handling.

      It also does not stamp bootstrap_version. A re-assert applies the routine
      elements and by construction not the console ones, so the unit is NOT at
      the current bootstrap version afterwards -- claiming otherwise would tell
      the drift report a unit is current while console elements are still
      missing. It records what it did, next to whatever version is already
      stamped, and leaves that version alone.
    #>
    [CmdletBinding()]
    param([string]$Requested = '')

    Write-BootstrapBanner '======================================================================' 'Cyan'
    Write-BootstrapBanner ' MAST bootstrap -- RE-ASSERT ONLY (no first-touch work, no reboot)' 'Cyan'
    Write-BootstrapBanner '======================================================================' 'Cyan'

    $selection = Get-MastReassertSelection -Requested $Requested
    if (@($selection.Problems).Count -gt 0) {
        foreach ($p in $selection.Problems) { Write-BootstrapMsg ("  [FAIL] {0}" -f $p) 'Red' }
        throw 'Nothing was run: the requested element list is not re-assertable.'
    }
    if (@($selection.Ids).Count -eq 0) {
        Write-BootstrapMsg '  Nothing selected; nothing to do.' 'Yellow'
        return 0
    }

    Write-BootstrapMsg ("  Applying {0} element(s): {1}" -f @($selection.Ids).Count, ($selection.Ids -join ', ')) 'White'
    $applied = @()
    $failed = @()
    foreach ($id in $selection.Ids) {
        $kind = $script:MastBootstrapElementActions[$id].Kind
        Write-BootstrapMsg '' 'Cyan'
        Write-BootstrapMsg ("=== {0} ({1}) ===" -f $id, $kind) 'Cyan'
        try {
            Invoke-MastBootstrapElement -Id $id
            $applied += $id
        } catch {
            # One element failing must not abandon the rest -- but the run must
            # not report success either.
            $failed += $id
            Write-BootstrapMsg ("  [FAIL] {0}: {1}" -f $id, $_.Exception.Message) 'Red'
        }
    }

    Write-MastReassertRecord -Applied $applied -Failed $failed -Requested $selection.Ids

    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- Re-assert summary ---' 'Cyan'
    Write-BootstrapMsg ("  applied: {0}" -f $(if ($applied.Count) { $applied -join ', ' } else { '(none)' })) 'White'
    if ($failed.Count -gt 0) {
        Write-BootstrapMsg ("  FAILED : {0}" -f ($failed -join ', ')) 'Red'
        Write-BootstrapBanner '[FAIL] Re-assert completed with failures.' 'Red'
        return 1
    }
    Write-BootstrapBanner '[OK] Re-assert complete.' 'Green'
    return 0
}

function Write-MastReassertRecord {
    # Merge a 'reassert' block into bootstrap-manifest.json WITHOUT touching
    # bootstrap_version: see Invoke-MastBootstrapReassert. On a unit that has no
    # manifest at all (provisioned before stamping existed) the version stays
    # null rather than being invented.
    param([string[]]$Applied, [string[]]$Failed, [string[]]$Requested)

    try {
        $dir = Join-Path $env:SystemDrive 'MAST'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $path = Join-Path $dir 'bootstrap-manifest.json'
        $doc = [ordered]@{}
        if (Test-Path -LiteralPath $path) {
            $existing = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($prop in $existing.PSObject.Properties) {
                if ($prop.Name -ne 'reassert') { $doc[$prop.Name] = $prop.Value }
            }
        }
        if (-not $doc.Contains('bootstrap_version')) { $doc['bootstrap_version'] = $null }
        $doc['reassert'] = [ordered]@{
            at             = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            script_version = $script:BootstrapVersion
            requested      = @($Requested)
            applied        = @($Applied)
            failed         = @($Failed)
        }
        ($doc | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $path -Encoding UTF8
        Write-BootstrapMsg ("  Recorded the re-assert in {0} (bootstrap_version left as-is)." -f $path) 'White'
    } catch {
        Write-BootstrapMsg ("  [WARN] could not record the re-assert: {0}" -f $_.Exception.Message) 'Yellow'
    }
}

$exitCode = 0
try {
    Write-BootstrapBanner '======================================================================' 'Cyan'
    Write-BootstrapBanner ' MAST bootstrap.ps1 (manual first-time setup)' 'Cyan'
    Write-BootstrapBanner '======================================================================' 'Cyan'
    Write-BootstrapMsg ("Log file (append): {0}" -f $script:BootstrapLog) 'DarkGray'

    if ($ReassertOnly) {
        # Converge an already-provisioned unit. Returns rather than falling
        # through: everything below this point is first-touch work.
        $script:exitCode = Invoke-MastBootstrapReassert -Requested $Elements
        exit $script:exitCode
    }

    # First, ahead of the prompts: a machine that fails this must be left untouched.
    Assert-MastUnitHardware -IsVmTestRun:$VmTestRun

    # Read-only, and deliberately separate from the assert above: a wrong BIOS
    # power policy is worth an operator's attention but is not a reason to
    # refuse to build the unit.
    Show-MastFirmwarePowerPolicy -IsNonInteractive:$NonInteractive

    if ([string]::IsNullOrWhiteSpace($MastHostName)) {
        if ($NonInteractive) {
            throw "Pass -MastHostName mastNN (required when -NonInteractive is set)."
        }
        Write-BootstrapMsg '' 'White'
        Write-BootstrapMsg 'UNIT HOSTNAME (Windows computer name)' 'Yellow'
        Write-BootstrapMsg '  Examples: mast01, mast05. Max 15 characters; letters, digits, hyphen only.' 'Yellow'
        Write-BootstrapMsg '  This name must match what the provisioning server will use in DNS/hosts.' 'Yellow'
        # Default to the current computer name so a re-run keeps the machine as-is on
        # plain Enter. On a bare unit the current name is the throwaway OEM name from
        # autounattend -- the operator types the real mastNN over it.
        $MastHostName = Read-Host ('Enter MastHostName [{0}]' -f $env:COMPUTERNAME)
        if ([string]::IsNullOrWhiteSpace($MastHostName)) { $MastHostName = $env:COMPUTERNAME }
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
        # Default to the previously persisted choice (re-run), else ns.
        $siteDefault = 'ns'
        $persistedSiteFile = Join-Path (Join-Path $env:ProgramData 'MAST') 'site.txt'
        if (Test-Path -LiteralPath $persistedSiteFile) {
            $prevSite = Get-Content -LiteralPath $persistedSiteFile -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($prevSite) { $prevSite = $prevSite.Trim().ToLower() }
            if ($knownSites -contains $prevSite) { $siteDefault = $prevSite }
        }
        Write-BootstrapMsg '' 'White'
        Write-BootstrapMsg 'SITE (selects the unit configuration profile)' 'Yellow'
        Write-BootstrapMsg ('  Known sites: {0}. Default: {1}.' -f ($knownSites -join ', '), $siteDefault) 'Yellow'
        $Site = Read-Host ('Enter site [{0}]' -f $siteDefault)
        if ([string]::IsNullOrWhiteSpace($Site)) { $Site = $siteDefault }
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

    # --- Time zone: Israel Standard Time with automatic DST ---
    # The autounattend answer file already sets the zone, but machines have
    # shown up on the right zone with automatic DST adjustment DISABLED
    # (DynamicDaylightTimeDisabled=1), leaving the local clock an hour off all
    # summer. Assert both here: tzutil /s without the _dstoff suffix sets the
    # zone AND re-enables dynamic DST in one idempotent call.
    Write-BootstrapMsg '' 'Cyan'
    Invoke-MastBootstrapElement -Id 'timezone-israel-dst'
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
    Invoke-MastBootstrapElement -Id 'windows-update-suppress'
    Write-BootstrapMsg '' 'Cyan'
    Invoke-MastBootstrapElement -Id 'popup-notification-suppress'
    Write-BootstrapMsg '' 'Cyan'
    Invoke-MastBootstrapElement -Id 'locale-en-us'
    Write-BootstrapMsg '' 'Cyan'
    Invoke-MastBootstrapElement -Id 'telemetry-privacy-harden'
    Write-BootstrapMsg '' 'Cyan'
    Invoke-MastBootstrapElement -Id 'service-trim'
    Write-BootstrapMsg '' 'Cyan'
    Invoke-MastBootstrapElement -Id 'dhcp-ipv4'
    Write-BootstrapMsg '' 'Cyan'
    Invoke-MastBootstrapElement -Id 'winrm-http-basic'
    Write-BootstrapMsg '' 'Cyan'
    Invoke-MastBootstrapElement -Id 'openssh-from-msi'
    Write-BootstrapMsg '' 'Cyan'
    Invoke-MastBootstrapElement -Id 'firewall-off'
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
            Write-BootstrapMsg '  Copy the Npcap installer alongside bootstrap.ps1 and re-run, or install Npcap manually.' 'Yellow'
            Write-BootstrapMsg '  Packet capture (Wireshark, etc.) will not work until Npcap is installed.' 'Yellow'
        } else {
            Write-BootstrapMsg ("  Launching Npcap installer GUI: {0}" -f $npcapInstaller) 'White'
            Write-BootstrapMsg '  Click through the installer; recommended options: WinPcap-compatible mode + loopback support.' 'Yellow'
            try {
                $npcapProc = Start-Process -FilePath $npcapInstaller -PassThru -Wait
                $npcapExit = $null
                try { $npcapExit = $npcapProc.ExitCode } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
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

    Write-BootstrapMsg '' 'Cyan'
    Write-BootstrapMsg '--- ExecutionPolicy ---' 'Cyan'
    Set-MastExecutionPolicy

    # Stamp the bootstrap version so the fleet drift report can tell which bootstrap
    # this unit ran (and therefore which newer bootstrap elements it may be missing).
    try {
        $bootStampDir = Join-Path $env:SystemDrive 'MAST'
        if (-not (Test-Path $bootStampDir)) { New-Item -ItemType Directory -Path $bootStampDir -Force | Out-Null }
        $bootStamp = [ordered]@{
            bootstrap_version = $script:BootstrapVersion
            bootstrapped_at   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            hostname          = $MastHostName
            script            = 'bootstrap.ps1'
        }
        # Carries whether a human was told about a bad BIOS power policy and
        # said 'yes, I know'. Without this, an acknowledged-bad unit is
        # indistinguishable later from one nobody ever checked.
        if ($script:BiosCheckFacts) { $bootStamp['bios_check'] = $script:BiosCheckFacts }
        $bootStamp | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $bootStampDir 'bootstrap-manifest.json') -Encoding UTF8
        Write-BootstrapMsg ("  Stamped bootstrap version {0} to C:\MAST\bootstrap-manifest.json" -f $script:BootstrapVersion) 'White'
    } catch {
        Write-BootstrapMsg ("  [WARN] could not write bootstrap-manifest.json: {0}" -f $_.Exception.Message) 'Yellow'
    }

    Write-BootstrapDesktopReport -HostNm $MastHostName -SiteCode $Site

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

    # Last, so the drive notice is the final thing on screen before any reboot
    # countdown.
    Find-MastBootstrapMedia
    if ($script:BootstrapMediaIsRemovable) {
        Write-BootstrapBanner '' 'White'
        Write-BootstrapBanner '======================================================================' 'Yellow'
        Write-BootstrapBanner (' REMOVE THE BOOTSTRAP DRIVE ({0}) NOW' -f $script:BootstrapMediaLetter) 'Yellow'
        Write-BootstrapBanner '======================================================================' 'Yellow'
        if ($script:BootstrapMediaOnD) {
            Write-BootstrapMsg '  It is sitting on D:, which the index RAM disk needs. A drive left plugged' 'Yellow'
            Write-BootstrapMsg '  in is picked up again on the next boot and takes D: back, so provisioning' 'Yellow'
            Write-BootstrapMsg '  will fail at the imdisk mount. Only unplugging it is durable.' 'Yellow'
        } else {
            Write-BootstrapMsg '  Left plugged in, it takes a drive letter again on the next boot.' 'Yellow'
        }
    }

    # Before the reboot notice, so an incomplete run is the last thing read.
    if ($script:BootstrapBlockers.Count -gt 0) {
        $exitCode = Get-MastBootstrapExitCode -Blockers $script:BootstrapBlockers
        Write-BootstrapBanner '' 'White'
        Write-BootstrapBanner '======================================================================' 'Red'
        Write-BootstrapBanner ' BOOTSTRAP INCOMPLETE' 'Red'
        Write-BootstrapBanner '======================================================================' 'Red'
        foreach ($b in $script:BootstrapBlockers) { Write-BootstrapMsg ("  - {0}" -f $b) 'Red' }
        Write-BootstrapMsg '' 'Red'
        Write-BootstrapMsg '  The machine was changed, but it is not ready. Fix the above and re-run;' 'Red'
        Write-BootstrapMsg '  bootstrap is idempotent.' 'Red'
        Write-BootstrapMsg ("  Full log: {0}" -f $script:BootstrapLog) 'Yellow'
    }

    if ($RebootAfterBootstrap) {
        Write-BootstrapMsg '' 'Yellow'
        if ($script:BootstrapMediaIsRemovable) {
            Write-BootstrapMsg 'Unplug the drive BEFORE the reboot below completes.' 'Red'
        }
        Write-BootstrapMsg 'Reboot in 90 seconds (-RebootAfterBootstrap). Cancel: shutdown.exe /a' 'Yellow'
        & shutdown.exe /r /t 90 /c "MAST bootstrap complete; rebooting."
    }
}
catch {
    $exitCode = 1
    Write-BootstrapMsg '' 'Red'
    Write-BootstrapBanner $(if ($ReassertOnly) { '[FAIL] MAST re-assert did not complete.' } else { '[FAIL] MAST bootstrap did not complete.' }) 'Red'
    Write-BootstrapMsg $_.Exception.Message 'Red'
    Write-BootstrapMsg ('At line: {0}' -f $_.InvocationInfo.PositionMessage) 'DarkRed'
    Write-BootstrapMsg '' 'Yellow'
    # The WinRM hint belongs to first touch, where a Public profile is the usual
    # cause. In a re-assert it is noise pointing at the wrong thing.
    if (-not $ReassertOnly) {
        Write-BootstrapMsg 'If the error mentions Public network or AllowUnencrypted, fix profiles (see log) and re-run.' 'Yellow'
    }
    Write-BootstrapMsg ("Full log: {0}" -f $script:BootstrapLog) 'Yellow'
}

exit $exitCode
