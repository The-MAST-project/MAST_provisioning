#Requires -Version 5.1
<#
.SYNOPSIS
  Autonomous MAST provisioning driver -- replaces run-prov-test.py once stable.

.DESCRIPTION
  For each unit in server/unit-registry.json:
    1. Reachability check (ping + WinRM)
    2. Build the latest payload via build-mast.ps1
    3. Compare build-manifest.json (server) vs installed-manifest.json (unit)
       - hash matches  -> log UNIT_SKIP and continue
    4. SMB pull: unit connects to \\<prov-server>\mast-staging and robocopy's payload
       (net use + robocopy via Invoke-Command; no credential forwarding or CredSSP)
    5. Run execute-mast-provisioning.ps1 on the unit
    6. Verify smoke markers, write structured logs

  Designed to run as a Task Scheduler job on the provisioning server every
  N minutes. Idempotent -- units already at the current payload_hash are
  skipped without rebuild side-effects (we still rebuild because build is
  cheap once binaries are cached, and it keeps the payload_hash fresh; this
  can be inverted to "build once per run" if scale demands).

.PARAMETER RepoTop
  Path to MAST_provisioning/ (the repo root). Defaults to the script's
  great-grandparent so the script can live at server/check-and-provision.ps1.

.PARAMETER UnitRegistry
  Path to unit-registry.json. Default: <RepoTop>\server\unit-registry.json

.PARAMETER VaultCreds
  Path to vault/creds.json. Default: <RepoTop>\vault\creds.json

.PARAMETER Modules
  Optional explicit module list, overriding each unit's "modules" entry.

.PARAMETER OnlyHosts
  Optional list of hostnames to process (others are skipped).

.PARAMETER DryRun
  Log what would happen but skip the transfer / execute / manifest-write steps.

.PARAMETER Force
  Provision even if installed-manifest.json hash matches build-manifest.json.

.PARAMETER WinRMUseSSL
  Use HTTPS (5986) and NTLM auth instead of HTTP (5985) Basic. Recommended
  for steady state once each unit has a cert installed.

.NOTES
  Logs:
    C:\MAST\logs\prov\sessions\run-<timestamp>\run-<timestamp>.log
    C:\MAST\logs\prov\activity.csv
    C:\MAST\logs\prov\last-error.log

  Exit codes:
    0  all units OK or SKIPPED
    1  one or more units FAIL / UNREACHABLE / EXCEPTION
    2  fatal startup error (registry / creds missing)
#>

[CmdletBinding()]
param(
    [string]   $RepoTop      = '',
    [string]   $UnitRegistry,
    [string]   $VaultCreds,
    [string[]] $Modules,
    [string[]] $OnlyHosts,
    # Proxy mode passed through to build-mast.ps1 (weizmann|direct). 'direct' is
    # for provisioning a unit that cannot reach bcproxy (e.g. a bench link-local
    # switch with the unit's own internet uplink). The proxy module then clears
    # all proxy surfaces on the unit -- re-run the proxy module with a weizmann
    # build once the unit is on a campus/site network.
    [ValidateSet('weizmann','direct')]
    [string]   $ProxyMode = 'weizmann',
    [switch]   $DryRun,
    [switch]   $Force,
    [switch]   $WinRMUseSSL,
    [switch]   $TestMode,
    [int]      $MaintenanceWindowStart = -1,
    [int]      $MaintenanceWindowEnd   = -1
)

$ErrorActionPreference = 'Stop'

if (-not $RepoTop) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
                 elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
                 elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
                 else { (Get-Location).Path }
    # This script lives at <RepoTop>\server\check-and-provision.ps1
    $RepoTop = Split-Path -Parent $scriptDir
}

# ---------------------------------------------------------------------------
# Paths and logging
# ---------------------------------------------------------------------------
if (-not $UnitRegistry) { $UnitRegistry = Join-Path $RepoTop 'server\unit-registry.json' }
if (-not $VaultCreds)   { $VaultCreds   = Join-Path $RepoTop 'vault\creds.json' }

. (Join-Path $RepoTop 'server\lib\mast-log.ps1')
Import-Module (Join-Path $RepoTop 'server\lib\mast-modules.psm1') -Force -DisableNameChecking

# Cached "all modules discovered on disk" list. Used as the fall-back when
# neither -Modules nor the unit's registry entry specifies modules. See
# Get-AllProviderModules in server\lib\mast-modules.psm1 for the source of truth.
$AllProviderModules = Get-AllProviderModules -ProvidersRoot (Join-Path $RepoTop 'server\providers')

# Dot-source the SMB pre-flight helper. The actual check call is below,
# after vault/creds are loaded (line ~320), so we have the transfer
# password to run the loopback auth smoke test.
. (Join-Path $RepoTop 'server\lib\preflight-smb.ps1')

$mastLogsBase   = Get-MastLogsBase
$provLogsStable = Get-MastProvLogsBase

$RunId = "run-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$RunStartUtc = (Get-Date).ToUniversalTime()
$LogRoot = Get-MastProvSessionDir $RunId

# Per-cycle counters and outcome map written to last-run.json at exit so a
# Phase 3 alert can fire when no fresh heartbeat appears on the prov server.
$UnitsChecked = 0
$UnitsUpdated = 0
$UnitsFailed  = 0
$UnitOutcomes = @{}

$RunLogPath  = Join-Path $LogRoot "$RunId.log"
$ActivityCsv = Get-MastProvActivityCsv
$LastErrLog  = Get-MastProvLastErrLog

if (-not (Test-Path $ActivityCsv)) {
    'timestamp_utc,run_id,unit,outcome,reason,duration_s,payload_hash,git_sha' |
        Out-File -FilePath $ActivityCsv -Encoding UTF8
}

function Log-Event {
    param(
        [Parameter(Mandatory)][string]$EventType,
        [hashtable]$Fields = @{}
    )
    $parts = @("[$(Now-Utc)]", $EventType)
    foreach ($k in $Fields.Keys) {
        $parts += "$k=$($Fields[$k])"
    }
    $line = $parts -join '  '
    $line | Tee-Object -FilePath $RunLogPath -Append | Write-Host
}

function Log-Activity {
    param(
        [string]$Unit,
        [string]$Outcome,
        [string]$Reason = '',
        [int]   $DurationS = 0,
        [string]$PayloadHash = '',
        [string]$GitSha = ''
    )
    $row = @(
        (Now-Utc), $RunId, $Unit, $Outcome, $Reason, $DurationS, $PayloadHash, $GitSha
    ) -join ','
    Add-Content -Path $ActivityCsv -Value $row -Encoding UTF8
    $script:UnitOutcomes[$Unit] = $Outcome
}

# ---------------------------------------------------------------------------
# Per-unit progress heartbeat. A System.Timers.Timer ticks every 60 s while a
# long-running phase (transfer, execute) is active and emits a UNIT_PROGRESS
# line. The action runs on a thread-pool thread; only Add-Content is used
# inside it for thread safety.
# ---------------------------------------------------------------------------
$script:ProgressTimer  = $null
$script:ProgressSrcId  = $null

function Start-UnitProgressTimer {
    param(
        [Parameter(Mandatory)][string]$Unit,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][DateTime]$StartUtc
    )
    Stop-UnitProgressTimer
    $script:ProgressSrcId = "MastUnitProgress-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $script:ProgressTimer = New-Object System.Timers.Timer
    $script:ProgressTimer.Interval  = 60000
    $script:ProgressTimer.AutoReset = $true
    $msg = [pscustomobject]@{
        Unit       = $Unit
        Phase      = $Phase
        StartUtc   = $StartUtc
        LogPath    = $RunLogPath
    }
    $null = Register-ObjectEvent -InputObject $script:ProgressTimer -EventName Elapsed `
        -SourceIdentifier $script:ProgressSrcId -MessageData $msg `
        -Action {
            try {
                $m   = $Event.MessageData
                $now = (Get-Date).ToUniversalTime()
                $elapsed = [int]($now - $m.StartUtc).TotalSeconds
                $line = "[{0}]  UNIT_PROGRESS  unit={1}  phase={2}  elapsed_s={3}" -f `
                    $now.ToString('yyyy-MM-ddTHH:mm:ssZ'), $m.Unit, $m.Phase, $elapsed
                Add-Content -Path $m.LogPath -Value $line -Encoding UTF8
            } catch {}
        }
    $script:ProgressTimer.Start()
}

function Stop-UnitProgressTimer {
    try {
        if ($script:ProgressTimer) {
            $script:ProgressTimer.Stop()
            $script:ProgressTimer.Dispose()
        }
    } catch {}
    try {
        if ($script:ProgressSrcId) {
            Unregister-Event -SourceIdentifier $script:ProgressSrcId -ErrorAction SilentlyContinue
            Get-Job -Name $script:ProgressSrcId -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    $script:ProgressTimer = $null
    $script:ProgressSrcId = $null
}

# Returns @{ allowed=[bool]; current=HH:mm; window="HH:00-HH:00"; reason=... }.
# A unit with no maintenance_window in its registry entry is allowed at any time
# (preserves prior behavior for partially configured registries). The -MaintenanceWindowStart
# and -MaintenanceWindowEnd script parameters, when supplied (>=0), override the
# per-unit values for an ad-hoc fleet-wide push.
function Test-InMaintenanceWindow {
    param([Parameter(Mandatory)]$Unit)

    $startH = $null; $endH = $null; $tz = $null
    if ($MaintenanceWindowStart -ge 0 -and $MaintenanceWindowEnd -ge 0) {
        $startH = $MaintenanceWindowStart
        $endH   = $MaintenanceWindowEnd
        $tz     = if ($Unit.timezone) { [string]$Unit.timezone } else { $null }
    } elseif ($Unit.maintenance_window) {
        $mw = $Unit.maintenance_window
        if (-not ($mw.PSObject.Properties.Match('start_hour').Count) -or
            -not ($mw.PSObject.Properties.Match('end_hour').Count)) {
            return @{ allowed=$true; reason='window_fields_missing' }
        }
        $startH = [int]$mw.start_hour
        $endH   = [int]$mw.end_hour
        $tz     = if ($Unit.timezone) { [string]$Unit.timezone } else { $null }
    } else {
        return @{ allowed=$true; reason='no_window_configured' }
    }

    $nowUtc = [DateTime]::UtcNow
    try {
        if ($tz) {
            $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById($tz)
            $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($nowUtc, $zone)
        } else {
            $local = $nowUtc.ToLocalTime()
        }
    } catch {
        # Bad timezone id -- fall back to server local time but flag it.
        $local = $nowUtc.ToLocalTime()
        Log-Event 'MAINT_TZ_WARN' @{ unit=$Unit.hostname; tz=$tz; err=$_.Exception.Message }
    }

    $h = $local.Hour
    if ($startH -le $endH) {
        $inWin = ($h -ge $startH -and $h -lt $endH)
    } else {
        # Wrap case, e.g. 22-06 -> allowed if h>=start OR h<end.
        $inWin = ($h -ge $startH -or $h -lt $endH)
    }
    return @{
        allowed = [bool]$inWin
        current = $local.ToString('HH:mm')
        window  = ("{0:00}:00-{1:00}:00" -f $startH, $endH)
        tz      = $tz
    }
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Log-Event 'RUN_START' @{ run_id=$RunId; trigger=$(if ($env:USERNAME -eq 'SYSTEM') {'TaskScheduler'} else {'manual'}) }

if (-not (Test-Path $UnitRegistry)) {
    Log-Event 'FATAL' @{ reason='unit_registry_missing'; path=$UnitRegistry }
    exit 2
}
if (-not (Test-Path $VaultCreds)) {
    Log-Event 'FATAL' @{ reason='vault_creds_missing'; path=$VaultCreds }
    exit 2
}

$units = @(Get-Content $UnitRegistry -Raw | ConvertFrom-Json) |
    Where-Object { $_ -and $_.hostname }
$creds = Get-Content $VaultCreds -Raw | ConvertFrom-Json
if (-not $creds.unit) {
    Log-Event 'FATAL' @{ reason='creds_unit_missing' }
    exit 2
}

$unitUser = $creds.unit.user
# Basic auth wants the BARE local username: creds.json stores ".\mast" and
# WinRM Basic rejects the machine-relative form with "Access is denied"
# (vm_lib.py strips it the same way for pywinrm).
if ($unitUser -like '.\*') { $unitUser = $unitUser.Substring(2) }
$unitPass = $creds.unit.pass
$securePw = ConvertTo-SecureString $unitPass -AsPlainText -Force
$unitCred = New-Object System.Management.Automation.PSCredential($unitUser, $securePw)

if (-not $creds.smb -or -not $creds.smb.user -or -not $creds.smb.pass) {
    Log-Event 'FATAL' @{ reason='creds_smb_missing'; hint='Add smb.user and smb.pass to vault/creds.json' }
    exit 2
}
$smbUser    = $creds.smb.user
$smbPass    = $creds.smb.pass
$provServer = $env:COMPUTERNAME

# Host-side SMB pre-flight: catches the failure family that used to hang
# units on `net use` for many minutes (empty SmbServerNetworkInterface,
# RejectUnencryptedAccess vs share EncryptData mismatch, mast-transfer
# auth drift). Loud-fails the whole check-and-provision run rather than
# letting each unit independently rediscover the broken share.
# Source of truth: server\lib\preflight-smb.ps1.
$smbCheck = Test-MastSmbHostReady `
    -ShareNames @('mast-staging','mast-shared') `
    -TransferUser $smbUser `
    -TransferPass $smbPass `
    -Quiet
if (-not $smbCheck.Ok) {
    Log-Event 'PREFLIGHT_SMB_FAIL' @{ failures = @($smbCheck.Failures) }
    Write-Host "SMB pre-flight FAILED. Cannot provision any units."
    $smbCheck.Failures | ForEach-Object { Write-Host ("  - {0}" -f $_) }
    exit 1
}
Log-Event 'PREFLIGHT_SMB_OK' @{}

if ($OnlyHosts) {
    $units = $units | Where-Object { $OnlyHosts -contains $_.hostname }
}
Log-Event 'RUN_PLAN' @{ units=($units | ForEach-Object { $_.hostname }) -join ','; dry_run=$DryRun.IsPresent; force=$Force.IsPresent }

# ---------------------------------------------------------------------------
# Per-unit pipeline
# ---------------------------------------------------------------------------
$exitCode = 0

foreach ($unit in $units) {
    $UnitsChecked++
    $unitStart = Get-Date
    $hostname = $unit.hostname
    # Hostname is the identity / WinRM target (DNS must resolve). Legacy 'ip' field is ignored.
    # Precedence: -Modules CLI override > registry entry's "modules" > full disk-discovered set.
    # The third fallback exists so units can omit "modules" from unit-registry.json and pick up
    # newly-added providers automatically -- no per-unit list refresh needed.
    if ($Modules) {
        $modules = $Modules
    } elseif ($unit.PSObject.Properties.Match('modules').Count -gt 0 -and $unit.modules) {
        $modules = $unit.modules
    } else {
        $modules = $AllProviderModules
    }
    $payloadHash = ''
    $gitSha      = ''

    $resolved = $null
    try {
        $resolved = (
            [System.Net.Dns]::GetHostAddresses($hostname) |
              Where-Object AddressFamily -EQ ([System.Net.Sockets.AddressFamily]::InterNetwork) |
              Where-Object { $_.IPAddressToString -notmatch '^(127\.|169\.254\.)' } |
              Select-Object -First 1
        ).IPAddressToString
    } catch {}

    Log-Event 'UNIT_BEGIN' @{ unit=$hostname; resolved_ip=$resolved }

    try {
        # -------------------------------------------------------------------
        # 1. Reachability -- fast TCP check, no full WinRM round-trip yet
        # -------------------------------------------------------------------
        $port = if ($WinRMUseSSL) { 5986 } else { 5985 }
        $tcp = Test-NetConnection -ComputerName $hostname -Port $port -WarningAction SilentlyContinue
        if (-not $tcp.TcpTestSucceeded) {
            Log-Event 'UNIT_UNREACHABLE' @{ unit=$hostname; resolved_ip=$resolved }
            Log-Activity -Unit $hostname -Outcome 'UNREACHABLE' -Reason 'winrm_port_closed' `
                         -DurationS ([int]((Get-Date) - $unitStart).TotalSeconds)
            $exitCode = 1
            continue
        }

        # -------------------------------------------------------------------
        # 2. Open WinRM session
        # -------------------------------------------------------------------
        $sopts = New-PSSessionOption -SkipCACheck -SkipCNCheck
        $sessParams = @{
            ComputerName  = $hostname
            Credential    = $unitCred
            SessionOption = $sopts
        }
        if ($WinRMUseSSL) {
            $sessParams['UseSSL']        = $true
            $sessParams['Authentication'] = 'Negotiate'
        } else {
            $sessParams['Authentication'] = 'Basic'
        }
        $session = New-PSSession @sessParams

        try {
            # ---------------------------------------------------------------
            # 2a. Availability state recovery. If a prior cycle crashed
            # between the unavailable/available writes, the unit is silently
            # excluded from MAST scheduling. Treat the file as stale once
            # expected_return_utc has passed; otherwise honor a live lease
            # held by another run.
            # ---------------------------------------------------------------
            $avail = Invoke-Command -Session $session -ScriptBlock {
                $p = 'C:\MAST\status\availability.json'
                if (Test-Path $p) {
                    try { Get-Content $p -Raw -ErrorAction Stop | ConvertFrom-Json }
                    catch { $null }
                } else { $null }
            }
            if ($avail -and ($avail.PSObject.Properties.Match('available').Count) -and -not $avail.available) {
                $owner = if ($avail.PSObject.Properties.Match('lease_owner').Count) { [string]$avail.lease_owner } else { '' }
                $expUtc = $null
                if ($avail.PSObject.Properties.Match('expected_return_utc').Count -and $avail.expected_return_utc) {
                    try { $expUtc = [datetime]::Parse($avail.expected_return_utc).ToUniversalTime() } catch {}
                }
                $nowUtc = (Get-Date).ToUniversalTime()
                $isStale = ($null -ne $expUtc) -and ($nowUtc -gt $expUtc)
                $isOurs  = ($owner -eq $RunId)
                if ($isOurs) {
                    Log-Event 'AVAIL_LEASE_SELF' @{ unit=$hostname; owner=$owner; reason=$avail.reason }
                } elseif (-not $isStale) {
                    Log-Event 'AVAIL_LEASE_LIVE' @{ unit=$hostname; owner=$owner; reason=$avail.reason; expires=$(if ($expUtc) { $expUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { 'unknown' }) }
                    Log-Activity -Unit $hostname -Outcome 'SKIP' -Reason 'avail_lease_live' `
                                 -DurationS ([int]((Get-Date) - $unitStart).TotalSeconds)
                    continue
                } else {
                    Log-Event 'AVAIL_STALE_RECOVER' @{ unit=$hostname; prior_run=$owner; reason=$avail.reason; expired_utc=$expUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') }
                    # Fall through; the cycle will write a fresh availability+lease shortly.
                }
            }

            # ---------------------------------------------------------------
            # 3. Read installed-manifest.json (if any)
            # ---------------------------------------------------------------
            $installed = Invoke-Command -Session $session -ScriptBlock {
                $p = 'C:\MAST\installed-manifest.json'
                if (Test-Path $p) { Get-Content $p -Raw | ConvertFrom-Json } else { $null }
            }
            $installedHash = if ($installed) { $installed.payload_hash } else { $null }

            # ---------------------------------------------------------------
            # 4. Build payload (always -- cheap when binaries are cached)
            # ---------------------------------------------------------------
            Log-Event 'BUILD_START' @{ unit=$hostname }
            $buildScript = Join-Path $RepoTop 'build\build-mast.ps1'
            $buildLog = Join-Path $LogRoot "$RunId-$hostname-build.log"
            try {
                # Run build in-process to avoid Start-Process quoting edge cases.
                # OUT-OF-PROCESS build. In-process invocation (& $buildScript)
                # bit twice: this script's Set-StrictMode leaked into the callee
                # (PropertyNotFoundStrict on optional module.json keys), and in a
                # detached console the shared PowerShell host blocked the build
                # with zero output and zero CPU (mast01 first run). A child
                # powershell.exe is the same proven context the VM harness
                # builds in.
                $buildArgList = @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', $buildScript,
                    '-Top', $RepoTop,
                    '-HostName', $hostname,
                    '-ProxyMode', $ProxyMode
                )
                # Site selects the bootstrap config profile (config-bootstrap) and comes
                # SOLELY from the unit's registry entry -- the operator's bootstrap choice --
                # never from the hostname. If absent, build-mast's default applies; log it
                # loudly so a production unit cannot silently take the dev profile.
                if ($unit.site) {
                    $buildArgList += @('-Site', $unit.site)
                } else {
                    Log-Event 'SITE_MISSING' @{ unit=$hostname; note='no site in registry entry; build-mast default applies' }
                }
                if ($modules) { $buildArgList += @('-Modules', ($modules -join ',')) }
                if ($TestMode) {
                    $buildArgList += @('-TestMode', '-AllowMissingNoMachineLicense', '-AllowMissingGithubToken')
                }
                & powershell.exe @buildArgList *>&1 | Out-File -FilePath $buildLog -Encoding UTF8
                if ($LASTEXITCODE -ne 0) {
                    throw "build-mast.ps1 exited $LASTEXITCODE (log: $buildLog)"
                }
            } catch {
                $_ | Out-String | Out-File -FilePath "$buildLog.err" -Encoding UTF8
                Log-Event 'BUILD_FAIL' @{ unit=$hostname; exit_code=1; log=$buildLog }
                Log-Activity -Unit $hostname -Outcome 'BUILD_FAIL' -Reason "exception" `
                             -DurationS ([int]((Get-Date) - $unitStart).TotalSeconds)
                $exitCode = 1
                continue
            }
            $stagingDir = Join-Path $RepoTop "staging\$hostname\01-provisioning"
            $bm = Get-Content (Join-Path $stagingDir 'build-manifest.json') -Raw | ConvertFrom-Json
            $payloadHash = $bm.payload_hash
            $gitSha      = $bm.git_sha
            Log-Event 'BUILD_OK' @{ unit=$hostname; payload_hash=$payloadHash; git_sha=$gitSha }

            # ---------------------------------------------------------------
            # 5. Hash compare
            # ---------------------------------------------------------------
            if ($installedHash -eq $payloadHash -and -not $Force) {
                Log-Event 'UNIT_SKIP' @{ unit=$hostname; reason='already_current'; payload_hash=$payloadHash }
                Log-Activity -Unit $hostname -Outcome 'SKIP' -Reason 'already_current' `
                             -DurationS ([int]((Get-Date) - $unitStart).TotalSeconds) `
                             -PayloadHash $payloadHash -GitSha $gitSha
                continue
            }
            $installedDisplay = if ($installedHash) { $installedHash } else { 'none' }
            Log-Event 'HASH_CHECK' @{ unit=$hostname; installed=$installedDisplay; built=$payloadHash; result='NEEDS_UPDATE' }

            if ($DryRun) {
                Log-Event 'DRYRUN_STOP' @{ unit=$hostname; reason='would_transfer_and_execute' }
                Log-Activity -Unit $hostname -Outcome 'SKIP' -Reason 'dry_run' `
                             -DurationS ([int]((Get-Date) - $unitStart).TotalSeconds) `
                             -PayloadHash $payloadHash -GitSha $gitSha
                continue
            }

            # ---------------------------------------------------------------
            # 5b. Maintenance window gate. The hash check above runs at any
            # time (non-disruptive); the steps below (mark unavailable, SMB
            # pull, execute, reboot) only run inside the unit's window.
            # ---------------------------------------------------------------
            $mw = Test-InMaintenanceWindow -Unit $unit
            if (-not $mw.allowed) {
                Log-Event 'MAINT_SKIP' @{ unit=$hostname; reason='outside_window'; current=$mw.current; window=$mw.window; tz=$mw.tz }
                Log-Activity -Unit $hostname -Outcome 'SKIP_MAINTENANCE' `
                             -Reason "outside_window current=$($mw.current) window=$($mw.window)" `
                             -DurationS ([int]((Get-Date) - $unitStart).TotalSeconds) `
                             -PayloadHash $payloadHash -GitSha $gitSha
                continue
            }

            # ---------------------------------------------------------------
            # 6. Mark unit unavailable for science scheduling. The TTL bounds
            # how long the MAST scheduler will honor this state if our cycle
            # crashes; lease_owner identifies the run so a later cycle can
            # recognize its own abandoned write.
            # ---------------------------------------------------------------
            $availTtlSec = 7200  # 2 h; matches execute-lease default
            $sinceUtc    = (Get-Date).ToUniversalTime()
            $expectedUtc = $sinceUtc.AddSeconds($availTtlSec)
            Invoke-Command -Session $session -ScriptBlock {
                param($payloadHash, $sinceStr, $expectedStr, $owner)
                $statusDir = 'C:\MAST\status'
                New-Item -ItemType Directory -Force -Path $statusDir | Out-Null
                $tmp = Join-Path $statusDir 'availability.json.tmp'
                $a = [ordered]@{
                    available           = $false
                    reason              = 'provisioning'
                    since_utc           = $sinceStr
                    expected_return_utc = $expectedStr
                    lease_owner         = $owner
                    payload_hash        = $payloadHash
                }
                ($a | ConvertTo-Json) | Out-File -FilePath $tmp -Encoding UTF8 -NoNewline
                Move-Item -Force $tmp (Join-Path $statusDir 'availability.json')
            } -ArgumentList $payloadHash, `
                            $sinceUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'), `
                            $expectedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'), `
                            $RunId
            Log-Event 'AVAIL_SET' @{ unit=$hostname; available='false'; reason='provisioning'; expected_return_utc=$expectedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'); lease_owner=$RunId }

            # ---------------------------------------------------------------
            # 7. Transfer staging payload via SMB pull (robocopy on unit)
            # ---------------------------------------------------------------
            $unitStage  = "C:\mast-staging\$RunId"
            $srcUNC     = "\\$provServer\mast-staging\$hostname\01-provisioning"
            $files      = Get-ChildItem -Path $stagingDir -File
            $totalBytes = ($files | Measure-Object -Sum Length).Sum
            Log-Event 'TRANSFER_START' @{
                unit      = $hostname
                files     = $files.Count
                bytes     = $totalBytes
                src_unc   = $srcUNC
                dst_local = $unitStage
            }
            $tStart = Get-Date

            Start-UnitProgressTimer -Unit $hostname -Phase 'transfer' -StartUtc $tStart.ToUniversalTime()
            try {
                $pullScript = Join-Path $PSScriptRoot '..\client\mast-pull-staging.ps1'
                # Observability: the pull runs as a job on the main session while
                # the main thread polls the destination size over a second,
                # lightweight session. TRANSFER_PROGRESS answers "where are we,
                # at what rate, how long remains"; TRANSFER_STALL answers "is it
                # even working" (no byte movement across 4 consecutive polls).
                $pollSession = $null
                try { $pollSession = New-PSSession @sessParams } catch {}
                $xferJob = Invoke-Command -Session $session -FilePath $pullScript `
                    -ArgumentList $provServer, $hostname, $smbUser, $smbPass, $unitStage, $srcUNC -AsJob
                $pollIntervalS = 30
                $lastBytes = [long]0
                $stallPolls = 0
                while (-not (Wait-Job $xferJob -Timeout $pollIntervalS)) {
                    if (-not $pollSession) { continue }
                    try {
                        $done = Invoke-Command -Session $pollSession -ScriptBlock {
                            param($p)
                            [long]((Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue |
                                Measure-Object Length -Sum).Sum)
                        } -ArgumentList $unitStage
                        if (-not $done) { $done = [long]0 }
                        $elapsedS = [Math]::Max(1, ((Get-Date) - $tStart).TotalSeconds)
                        $winRate  = [Math]::Max(0, ($done - $lastBytes) / $pollIntervalS)
                        $avgRate  = $done / $elapsedS
                        $etaS = -1
                        if ($avgRate -gt 0) { $etaS = [int](($totalBytes - $done) / $avgRate) }
                        $pct = 0.0
                        if ($totalBytes -gt 0) { $pct = [Math]::Round(100.0 * $done / $totalBytes, 1) }
                        if ($done -le $lastBytes) { $stallPolls++ } else { $stallPolls = 0 }
                        Log-Event 'TRANSFER_PROGRESS' @{
                            unit        = $hostname
                            bytes_done  = $done
                            bytes_total = $totalBytes
                            pct         = $pct
                            rate_mbps   = [Math]::Round($winRate / 1MB, 1)
                            eta_s       = $etaS
                        }
                        if ($stallPolls -ge 4) {
                            Log-Event 'TRANSFER_STALL' @{
                                unit       = $hostname
                                bytes_done = $done
                                stalled_s  = [int]($pollIntervalS * $stallPolls)
                            }
                        }
                        $lastBytes = $done
                    } catch {}
                }
                $xferResult = Receive-Job $xferJob
                Remove-Job $xferJob -Force -ErrorAction SilentlyContinue
            } finally {
                Stop-UnitProgressTimer
                if ($pollSession) { Remove-PSSession $pollSession -ErrorAction SilentlyContinue }
            }

            $xferDur = [int]((Get-Date) - $tStart).TotalSeconds

            if ($xferResult.outcome -eq 'NET_USE_FAIL') {
                Log-Event 'TRANSFER_FAIL' @{
                    unit       = $hostname
                    reason     = 'net_use_failed'
                    rc         = $xferResult.rc
                    detail     = $xferResult.detail
                    duration_s = $xferDur
                }
                Log-Activity -Unit $hostname -Outcome 'TRANSFER_FAIL' `
                             -Reason "net_use_rc_$($xferResult.rc)" `
                             -DurationS ([int]((Get-Date) - $unitStart).TotalSeconds) `
                             -PayloadHash $payloadHash -GitSha $gitSha
                $exitCode = 1
                continue
            }

            if ($xferResult.outcome -eq 'ROBOCOPY_ERROR') {
                Log-Event 'TRANSFER_FAIL' @{
                    unit       = $hostname
                    reason     = 'robocopy_error'
                    rc         = $xferResult.rc
                    detail     = $xferResult.detail
                    duration_s = $xferDur
                }
                Log-Activity -Unit $hostname -Outcome 'TRANSFER_FAIL' `
                             -Reason "robocopy_rc_$($xferResult.rc)" `
                             -DurationS ([int]((Get-Date) - $unitStart).TotalSeconds) `
                             -PayloadHash $payloadHash -GitSha $gitSha
                $exitCode = 1
                continue
            }

            # rc 0 = no differences (idempotent re-run); rc 1 = files copied; 2-7 = warnings (non-fatal).
            $xferNote = $(
                if ($xferResult.rc -eq 0) { 'no_changes' }
                elseif ($xferResult.rc -eq 1) { 'files_copied' }
                else { "robocopy_warning_rc_$($xferResult.rc)" }
            )
            Log-Event 'TRANSFER_OK' @{
                unit        = $hostname
                duration_s  = $xferDur
                bytes       = $totalBytes
                robocopy_rc = $xferResult.rc
                note        = $xferNote
            }

            # ---------------------------------------------------------------
            # 8. Execute provisioning on the unit
            # ---------------------------------------------------------------
            Log-Event 'EXECUTE_START' @{ unit=$hostname; run_id=$RunId }
            $eStart = Get-Date
            Start-UnitProgressTimer -Unit $hostname -Phase 'execute' -StartUtc $eStart.ToUniversalTime()
            try {
                $execResult = Invoke-Command -Session $session -ScriptBlock {
                    param($stagePath, $provSrv, $smbUsr, $smbPwd, $runId, $heldBy)
                    Set-ExecutionPolicy Bypass -Scope Process -Force
                    # Suppress script output so the WinRM return value is just the exit code.
                    # -AllowReboot: autonomous orchestrator runs are allowed to schedule a
                    # post-run restart when the reboot provider flag is set.
                    $null = & (Join-Path $stagePath 'execute-mast-provisioning.ps1') `
                        -StagingPath $stagePath `
                        -ProvServer   $provSrv `
                        -SmbUser      $smbUsr `
                        -SmbPass      $smbPwd `
                        -RunId        $runId `
                        -HeldBy       $heldBy `
                        -AllowReboot
                    return [int]$LASTEXITCODE
                } -ArgumentList $unitStage, $provServer, $smbUser, $smbPass, $RunId, $provServer
            } finally {
                Stop-UnitProgressTimer
            }
            $execRc = [int]($execResult | Select-Object -Last 1)
            $eDur   = [int]((Get-Date) - $eStart).TotalSeconds
            if ($execRc -ne 0) {
                Log-Event 'EXECUTE_FAIL' @{ unit=$hostname; exit_code=$execRc; duration_s=$eDur }
                Log-Activity -Unit $hostname -Outcome 'EXECUTE_FAIL' -Reason "exit_$execRc" `
                             -DurationS ([int]((Get-Date) - $unitStart).TotalSeconds) `
                             -PayloadHash $payloadHash -GitSha $gitSha
                $exitCode = 1
                continue
            }
            Log-Event 'EXECUTE_OK' @{ unit=$hostname; duration_s=$eDur }

            # ---------------------------------------------------------------
            # 9. Smoke verification
            # ---------------------------------------------------------------
            Log-Event 'SMOKE_START' @{ unit=$hostname }
            $smokeResults = Invoke-Command -Session $session -ScriptBlock {
                param($mods)
                $logDir = Join-Path $env:SystemDrive 'MAST\logs\smoke'
                $out = @{}
                foreach ($m in $mods) {
                    $p = Join-Path $logDir "$m-smoke.txt"
                    if (Test-Path $p) {
                        $content = (Get-Content $p -Raw).Trim()
                        $out[$m] = if ($content) { $content } else { '<empty>' }
                    } else {
                        $out[$m] = '<missing>'
                    }
                }
                return $out
            } -ArgumentList (,$modules)

            $smokeFails = @()
            foreach ($m in $modules) {
                $val = $smokeResults[$m]
                if ($val -eq '<missing>' -or $val -eq '<empty>') {
                    Log-Event 'SMOKE_RESULT' @{ unit=$hostname; module=$m; status='FAIL'; reason=$val }
                    $smokeFails += $m
                } else {
                    Log-Event 'SMOKE_RESULT' @{ unit=$hostname; module=$m; status='OK' }
                }
            }

            if ($smokeFails.Count -gt 0) {
                Log-Event 'UNIT_FAIL' @{ unit=$hostname; reason='smoke_failures'; modules=($smokeFails -join ',') }
                Log-Activity -Unit $hostname -Outcome 'FAIL' -Reason "smoke:$($smokeFails -join '+')" `
                             -DurationS ([int]((Get-Date) - $unitStart).TotalSeconds) `
                             -PayloadHash $payloadHash -GitSha $gitSha
                $exitCode = 1
                continue
            }

            # ---------------------------------------------------------------
            # 10. Mark unit available again
            # ---------------------------------------------------------------
            Invoke-Command -Session $session -ScriptBlock {
                $statusDir = 'C:\MAST\status'
                New-Item -ItemType Directory -Force -Path $statusDir | Out-Null
                $tmp = Join-Path $statusDir 'availability.json.tmp'
                # available:true intentionally omits expected_return_utc and
                # lease_owner: the unit is in steady state, not under a lease.
                $a = [ordered]@{
                    available = $true
                    since_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                }
                ($a | ConvertTo-Json) | Out-File -FilePath $tmp -Encoding UTF8 -NoNewline
                Move-Item -Force $tmp (Join-Path $statusDir 'availability.json')
            }
            Log-Event 'AVAIL_SET' @{ unit=$hostname; available='true' }

            Log-Event 'UNIT_OK' @{ unit=$hostname; payload_hash=$payloadHash }
            Log-Activity -Unit $hostname -Outcome 'OK' -Reason 'updated' `
                         -DurationS ([int]((Get-Date) - $unitStart).TotalSeconds) `
                         -PayloadHash $payloadHash -GitSha $gitSha
        }
        finally {
            if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
        }
    }
    catch {
        $err = "$($_.Exception.GetType().Name): $($_.Exception.Message)"
        Log-Event 'EXCEPTION' @{ unit=$hostname; error=$err }
        $_.ScriptStackTrace | Out-File -FilePath $LastErrLog -Encoding UTF8
        Log-Activity -Unit $hostname -Outcome 'FAIL' -Reason "exception:$($_.Exception.GetType().Name)" `
                     -DurationS ([int]((Get-Date) - $unitStart).TotalSeconds) `
                     -PayloadHash $payloadHash -GitSha $gitSha
        $exitCode = 1
    }
}

# ---------------------------------------------------------------------------
# Heartbeat: write last-run.json so a Phase 3 alert can fire when no fresh
# cycle has landed within 2 * scheduled_interval. Counters are derived from
# the outcome map populated by Log-Activity so they always agree with the
# CSV.
#
# IMPORTANT - this is telemetry, NOT a unit-state cache.
# `unit_outcomes` records what THIS CYCLE DID (e.g. "we marked mast01 OK at
# 14:55:05Z"), not what is installed on the unit. The autonomous-provisioning
# requirements forbid caching per-unit installed state on the prov server --
# the unit's own `C:\MAST\installed-manifest.json` is the source of truth and
# is read fresh via WinRM at the top of every cycle.
#
# Consumers (Phase 3 alerting, Prometheus scrape) read last-run.json to
# answer "did a cycle complete recently?". The driver itself MUST NOT read
# last-run.json to make control-plane decisions (e.g. "skip mast01 because
# last cycle said OK"). If you find yourself wanting to read this file from
# the driver to short-circuit a unit, you are reintroducing the cache the
# design explicitly rejected -- re-probe the unit instead.
# ---------------------------------------------------------------------------
$RunEndUtc  = (Get-Date).ToUniversalTime()
$DurationS  = [int]($RunEndUtc - $RunStartUtc).TotalSeconds
foreach ($oc in $UnitOutcomes.Values) {
    if ($oc -eq 'OK') { $UnitsUpdated++ }
    elseif ($oc -eq 'FAIL' -or $oc -eq 'UNREACHABLE' -or $oc -eq 'BUILD_FAIL' -or `
            $oc -eq 'TRANSFER_FAIL' -or $oc -eq 'EXECUTE_FAIL') { $UnitsFailed++ }
}
try {
    $lastRun = [ordered]@{
        run_id        = $RunId
        started_utc   = $RunStartUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        ended_utc     = $RunEndUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        duration_s    = $DurationS
        units_checked = $UnitsChecked
        units_updated = $UnitsUpdated
        units_failed  = $UnitsFailed
        unit_outcomes = $UnitOutcomes
        exit_code     = $exitCode
    }
    Write-MastStatusFileAtomic -Path (Get-MastLastRunPath) -Object $lastRun
} catch {
    Log-Event 'HEARTBEAT_WRITE_FAIL' @{ err=$_.Exception.Message }
}

Log-Event 'RUN_END' @{ exit_code=$exitCode; units_checked=$UnitsChecked; units_updated=$UnitsUpdated; units_failed=$UnitsFailed; duration_s=$DurationS }
exit $exitCode
