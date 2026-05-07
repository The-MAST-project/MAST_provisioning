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
    4. WinRM push the staged payload to C:\mast-staging on the unit
       (uses Copy-Item -ToSession to avoid SMB credential complexity)
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
    C:\ProgramData\MAST\logs\prov\run-<timestamp>.log
    C:\ProgramData\MAST\logs\prov\activity.csv
    C:\ProgramData\MAST\logs\prov\last-error.log

  Exit codes:
    0  all units OK or SKIPPED
    1  one or more units FAIL / UNREACHABLE / EXCEPTION
    2  fatal startup error (registry / creds missing)
#>

[CmdletBinding()]
param(
    [string]   $RepoTop      = (Split-Path -Parent (Split-Path -Parent $PSCommandPath)),
    [string]   $UnitRegistry,
    [string]   $VaultCreds,
    [string[]] $Modules,
    [string[]] $OnlyHosts,
    [switch]   $DryRun,
    [switch]   $Force,
    [switch]   $WinRMUseSSL
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths and logging
# ---------------------------------------------------------------------------
if (-not $UnitRegistry) { $UnitRegistry = Join-Path $RepoTop 'server\unit-registry.json' }
if (-not $VaultCreds)   { $VaultCreds   = Join-Path $RepoTop 'vault\creds.json' }

$LogRoot = Join-Path $env:ProgramData 'MAST\logs\prov'
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

$RunId      = "run-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$RunLogPath = Join-Path $LogRoot "$RunId.log"
$ActivityCsv = Join-Path $LogRoot 'activity.csv'
$LastErrLog  = Join-Path $LogRoot 'last-error.log'

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
Log-Event 'RUN_START' @{ run_id=$RunId; trigger=if ($env:USERNAME -eq 'SYSTEM') {'TaskScheduler'} else {'manual'} }

if (-not (Test-Path $UnitRegistry)) {
    Log-Event 'FATAL' @{ reason='unit_registry_missing'; path=$UnitRegistry }
    exit 2
}
if (-not (Test-Path $VaultCreds)) {
    Log-Event 'FATAL' @{ reason='vault_creds_missing'; path=$VaultCreds }
    exit 2
}

$units = Get-Content $UnitRegistry -Raw | ConvertFrom-Json |
            Where-Object { -not $_._comment }
$creds = Get-Content $VaultCreds -Raw | ConvertFrom-Json
if (-not $creds.unit) {
    Log-Event 'FATAL' @{ reason='creds_unit_missing' }
    exit 2
}

$unitUser = $creds.unit.user
$unitPass = $creds.unit.pass
$securePw = ConvertTo-SecureString $unitPass -AsPlainText -Force
$unitCred = New-Object System.Management.Automation.PSCredential($unitUser, $securePw)

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
    $ip       = $unit.ip
    $modules  = if ($Modules) { $Modules } else { $unit.modules }
    $payloadHash = ''
    $gitSha      = ''

    Log-Event 'UNIT_BEGIN' @{ unit=$hostname; ip=$ip }

    try {
        # -------------------------------------------------------------------
        # 1. Reachability -- fast TCP check, no full WinRM round-trip yet
        # -------------------------------------------------------------------
        $tcp = Test-NetConnection -ComputerName $ip -Port (if ($WinRMUseSSL) {5986} else {5985}) -WarningAction SilentlyContinue
        if (-not $tcp.TcpTestSucceeded) {
            Log-Event 'UNIT_UNREACHABLE' @{ unit=$hostname; ip=$ip }
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
            ComputerName  = $ip
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
                $p = 'C:\ProgramData\MAST\installed-manifest.json'
                if (Test-Path $p) { Get-Content $p -Raw | ConvertFrom-Json } else { $null }
            }
            $installedHash = if ($installed) { $installed.payload_hash } else { $null }

            # ---------------------------------------------------------------
            # 4. Build payload (always -- cheap when binaries are cached)
            # ---------------------------------------------------------------
            Log-Event 'BUILD_START' @{ unit=$hostname }
            $buildScript = Join-Path $RepoTop 'build\build-mast.ps1'
            $buildArgs = @(
                '-NoProfile','-ExecutionPolicy','Bypass','-File', $buildScript,
                '-Top', $RepoTop, '-HostName', $hostname
            )
            if ($modules) { $buildArgs += @('-Modules', ($modules -join ',')) }
            $buildLog = Join-Path $LogRoot "$RunId-$hostname-build.log"
            $proc = Start-Process -FilePath powershell.exe -ArgumentList $buildArgs `
                                   -NoNewWindow -Wait -PassThru `
                                   -RedirectStandardOutput $buildLog -RedirectStandardError "$buildLog.err"
            if ($proc.ExitCode -ne 0) {
                Log-Event 'BUILD_FAIL' @{ unit=$hostname; exit_code=$proc.ExitCode; log=$buildLog }
                Log-Activity -Unit $hostname -Outcome 'BUILD_FAIL' -Reason "exit_$($proc.ExitCode)" `
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
            # 7. Transfer staging payload via WinRM (Copy-Item -ToSession)
            # ---------------------------------------------------------------
            $files = Get-ChildItem -Path $stagingDir -File
            $totalBytes = ($files | Measure-Object -Sum Length).Sum
            Log-Event 'TRANSFER_START' @{ unit=$hostname; files=$files.Count; bytes=$totalBytes }
            $tStart = Get-Date

            Invoke-Command -Session $session -ScriptBlock {
                if (Test-Path 'C:\mast-staging') {
                    Remove-Item 'C:\mast-staging' -Recurse -Force
                }
                New-Item -ItemType Directory -Force -Path 'C:\mast-staging' | Out-Null
            }

            $copied = 0
            foreach ($f in $files) {
                Copy-Item -Path $f.FullName -Destination 'C:\mast-staging\' `
                          -ToSession $session -Force
                $copied += $f.Length
                $elapsed = [int]((Get-Date) - $tStart).TotalSeconds
                # Heartbeat every ~30s, not every file (would spam for large fleets).
                if ($elapsed -gt 0 -and ($elapsed % 30) -lt 1) {
                    Log-Event 'TRANSFER_PROGRESS' @{ unit=$hostname; bytes_done=$copied; bytes_total=$totalBytes }
                }
            }
            Log-Event 'TRANSFER_OK' @{ unit=$hostname; duration_s=[int]((Get-Date) - $tStart).TotalSeconds; bytes=$copied }

            # ---------------------------------------------------------------
            # 8. Execute provisioning on the unit
            # ---------------------------------------------------------------
            Log-Event 'EXECUTE_START' @{ unit=$hostname }
            $eStart = Get-Date
            $execResult = Invoke-Command -Session $session -ScriptBlock {
                Set-ExecutionPolicy Bypass -Scope Process -Force
                & 'C:\mast-staging\execute-mast-provisioning.ps1' -StagingPath 'C:\mast-staging'
                return $LASTEXITCODE
            }
            $execRc = [int]$execResult
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
                $logDir = 'C:\ProgramData\MAST\logs'
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
