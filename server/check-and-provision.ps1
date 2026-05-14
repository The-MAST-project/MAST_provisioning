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
    [switch]   $DryRun,
    [switch]   $Force,
    [switch]   $WinRMUseSSL,
    [switch]   $TestMode
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

$mastLogsBase   = Get-MastLogsBase
$provLogsStable = Get-MastProvLogsBase

$RunId = "run-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$LogRoot = Get-MastProvSessionDir $RunId

$RunLogPath  = Join-Path $LogRoot "$RunId.log"
$ActivityCsv = Get-MastProvActivityCsv
$LastErrLog  = Get-MastProvLastErrLog

if (-not (Test-Path $ActivityCsv)) {
    'timestamp_utc,run_id,unit,outcome,reason,duration_s,payload_hash,git_sha' |
        Out-File -FilePath $ActivityCsv -Encoding UTF8
}

function Now-Utc { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

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

if ($OnlyHosts) {
    $units = $units | Where-Object { $OnlyHosts -contains $_.hostname }
}
Log-Event 'RUN_PLAN' @{ units=($units | ForEach-Object { $_.hostname }) -join ','; dry_run=$DryRun.IsPresent; force=$Force.IsPresent }

# ---------------------------------------------------------------------------
# Per-unit pipeline
# ---------------------------------------------------------------------------
$exitCode = 0

foreach ($unit in $units) {
    $unitStart = Get-Date
    $hostname = $unit.hostname
    # Hostname is the identity / WinRM target (DNS must resolve). Legacy 'ip' field is ignored.
    $modules  = if ($Modules) { $Modules } else { $unit.modules }
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
                $args = @{
                    Top        = $RepoTop
                    HostName   = $hostname
                }
                if ($modules) { $args.Modules = $modules }
                if ($TestMode) {
                    $args.TestMode = $true
                    $args.AllowMissingNoMachineLicense = $true
                    $args.AllowMissingGithubToken = $true
                }
                & $buildScript @args *>&1 | Out-File -FilePath $buildLog -Encoding UTF8
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
            # 6. Mark unit unavailable for science scheduling
            # ---------------------------------------------------------------
            Invoke-Command -Session $session -ScriptBlock {
                param($payloadHash)
                $statusDir = 'C:\ProgramData\MAST\status'
                New-Item -ItemType Directory -Force -Path $statusDir | Out-Null
                $tmp = Join-Path $statusDir 'availability.json.tmp'
                $a = @{
                    available    = $false
                    reason       = 'provisioning'
                    since_utc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                    payload_hash = $payloadHash
                }
                ($a | ConvertTo-Json) | Out-File -FilePath $tmp -Encoding UTF8
                Move-Item -Force $tmp (Join-Path $statusDir 'availability.json')
            } -ArgumentList $payloadHash
            Log-Event 'AVAIL_SET' @{ unit=$hostname; available='false'; reason='provisioning' }

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

            $pullScript = Join-Path $PSScriptRoot '..\client\mast-pull-staging.ps1'
            $xferResult = Invoke-Command -Session $session -FilePath $pullScript `
                -ArgumentList $provServer, $hostname, $smbUser, $smbPass, $unitStage, $srcUNC

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
            Log-Event 'EXECUTE_START' @{ unit=$hostname }
            $eStart = Get-Date
            $execResult = Invoke-Command -Session $session -ScriptBlock {
                param($stagePath)
                Set-ExecutionPolicy Bypass -Scope Process -Force
                # Suppress script output so the WinRM return value is just the exit code.
                $null = & (Join-Path $stagePath 'execute-mast-provisioning.ps1') -StagingPath $stagePath
                return [int]$LASTEXITCODE
            } -ArgumentList $unitStage
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
                $statusDir = 'C:\ProgramData\MAST\status'
                $tmp = Join-Path $statusDir 'availability.json.tmp'
                $a = @{
                    available = $true
                    since_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                }
                ($a | ConvertTo-Json) | Out-File -FilePath $tmp -Encoding UTF8
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

Log-Event 'RUN_END' @{ exit_code=$exitCode }
exit $exitCode
