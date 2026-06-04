#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Post-bootstrap onboarder for a MAST unit: provision, register, hand off.

.DESCRIPTION
  Assumes client\bootstrap-winrm.ps1 has ALREADY run on this machine.
  bootstrap-winrm.ps1 is the single source of truth for first-time prep:
  the 'mast' admin account, WinRM HTTP/5985 + Basic, firewall, OpenSSH, Npcap,
  computer rename, and Windows Update suppression. This script does NOT repeat
  any of that. Stage 0 only verifies bootstrap left the machine in the expected
  state and fails fast (telling you to run bootstrap first) if it did not.

  From there it drives the unit to steady state. Runs locally on the unit.

  Stages:
    0  PREFLIGHT  Verify admin + that bootstrap ran (mast account, WinRM) + prov reachable
    1  PROVISION  Trigger check-and-provision.ps1 on the prov server for this unit
    2  REGISTER   Append this unit to the prov server's unit-registry.json
    3  HANDOFF    Mark availability=true (ready for the autonomous loop)

  Idempotent. Re-running on a partially-onboarded machine resumes from
  the last completed stage (checkpoint at C:\ProgramData\MAST\onboarding-checkpoint.json).

  All progress is logged structured at C:\MAST\logs\onboarding\onboarding.log
  and (from the PROVISION stage onward) mirrored to the prov server at
  C:\MAST\logs\onboarding\<hostname>.log.

.PARAMETER HostName
  Required. The unit's MAST hostname (mast01..mast20). Must already match the
  name bootstrap-winrm.ps1 set on this machine.

.PARAMETER ProvServer
  Required. IP of the provisioning server.

.PARAMETER ProvUser
  Account on the prov server with read access to its repo / staging dir.
  Format ".\\mast" or "DOMAIN\\user". Default ".\\mast".

.PARAMETER ResumeFrom
  Stage to resume from (0..3). Default: read checkpoint and continue.

.PARAMETER Modules
  Optional explicit module list for the provisioning step.

.PARAMETER MastUser
  Local 'mast' admin account name to verify in preflight (default 'mast').

.PARAMETER DryRun
  Log every action but do not execute side effects.

.EXAMPLE
  # After bootstrap-winrm.ps1 has already run on the unit:
  .\onboard-mast-unit.ps1 -HostName mast01 -ProvServer 192.168.56.1

  # Resume after a failed PROVISION stage:
  .\onboard-mast-unit.ps1 -HostName mast01 -ProvServer 192.168.56.1 -ResumeFrom 1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^mast(0[1-9]|1[0-9]|20)$')]
    [string]$HostName,

    [Parameter(Mandatory=$true)]
    [string]$ProvServer,

    [string]   $ProvUser    = '.\mast',
    [int]      $ResumeFrom   = -1,
    [string[]] $Modules,
    [string]   $MastUser     = 'mast',
    [switch]   $DryRun
)

$ErrorActionPreference = 'Stop'

# mast-log.ps1: try next to this script (ISO/USB deploy) then repo layout
$_mastLogDot = Join-Path $PSScriptRoot 'mast-log.ps1'
if (-not (Test-Path $_mastLogDot)) { $_mastLogDot = Join-Path (Split-Path -Parent $PSScriptRoot) 'server\lib\mast-log.ps1' }
if (Test-Path $_mastLogDot) { . $_mastLogDot }

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$DataRoot       = Join-Path $env:ProgramData 'MAST'
$mastLogsBase   = Join-Path $env:SystemDrive 'MAST\logs'
$LogDir         = Join-Path $mastLogsBase 'onboarding'
$OnboardingLog  = Join-Path $LogDir 'onboarding.log'
$CheckpointPath = Join-Path $DataRoot 'onboarding-checkpoint.json'
$StatusDir      = Join-Path $env:SystemDrive 'MAST\status'

New-Item -ItemType Directory -Force -Path $DataRoot, $LogDir, $StatusDir | Out-Null

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if (-not (Get-Command Now-Utc -ErrorAction SilentlyContinue)) {
    function Now-Utc { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
}

function Log-Event {
    param(
        [Parameter(Mandatory)][string]$EventType,
        [hashtable]$Fields = @{}
    )
    $parts = @("[$(Now-Utc)]", $EventType)
    foreach ($k in $Fields.Keys) { $parts += "$k=$($Fields[$k])" }
    $line = $parts -join '  '
    $line | Tee-Object -FilePath $OnboardingLog -Append | Write-Host
}

function Mirror-ToProvServer {
    param([string]$Line)
    if (-not $script:ProvSession) { return }
    try {
        Invoke-Command -Session $script:ProvSession -ScriptBlock {
            param($host, $line)
            $remoteDir = Join-Path (Join-Path $env:SystemDrive 'MAST\logs') 'onboarding'
            New-Item -ItemType Directory -Force -Path $remoteDir | Out-Null
            $remoteLog = Join-Path $remoteDir "$host.log"
            Add-Content -Path $remoteLog -Value $line -Encoding UTF8
        } -ArgumentList $HostName, $Line -ErrorAction Stop
    } catch {
        # Don't let mirror failures break onboarding
    }
}

# ---------------------------------------------------------------------------
# Checkpoint
# ---------------------------------------------------------------------------
function Read-Checkpoint {
    if (-not (Test-Path $CheckpointPath)) {
        return @{ unit = $HostName; last_completed_stage = -1; timestamp_utc = (Now-Utc) }
    }
    return Get-Content $CheckpointPath -Raw | ConvertFrom-Json | ConvertTo-Hashtable
}

function ConvertTo-Hashtable {
    param([Parameter(ValueFromPipeline)] $Obj)
    process {
        $h = @{}
        foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    }
}

function Write-Checkpoint {
    param([int]$LastCompletedStage)
    $cp = @{
        unit                  = $HostName
        last_completed_stage  = $LastCompletedStage
        timestamp_utc         = (Now-Utc)
    }
    $tmp = "$CheckpointPath.tmp"
    ($cp | ConvertTo-Json) | Out-File -FilePath $tmp -Encoding UTF8
    Move-Item -Force $tmp $CheckpointPath
}

# ---------------------------------------------------------------------------
# Stage runner
# ---------------------------------------------------------------------------
function Run-Stage {
    param(
        [int]$Index,
        [string]$Name,
        [scriptblock]$Action
    )
    Log-Event 'STAGE_START' @{ stage=$Index; name=$Name }
    $start = Get-Date
    if ($DryRun) {
        Log-Event 'DRYRUN' @{ stage=$Index; name=$Name; reason='would_execute' }
    } else {
        & $Action
    }
    $dur = [int]((Get-Date) - $start).TotalSeconds
    Log-Event 'STAGE_OK' @{ stage=$Index; name=$Name; duration_s=$dur }
    Write-Checkpoint -LastCompletedStage $Index
}

# ---------------------------------------------------------------------------
# Stage 0 - PREFLIGHT  (verify admin + that bootstrap-winrm.ps1 already ran)
# ---------------------------------------------------------------------------
function Stage-Preflight {
    Log-Event 'CHECK' @{ check='admin_rights' }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')
    if (-not $isAdmin) { throw "Must run as Administrator." }
    Log-Event 'CHECK_OK' @{ check='admin_rights' }

    # This onboarder assumes bootstrap-winrm.ps1 already did first-time prep.
    # Verify its two load-bearing outputs rather than recreating them.
    Log-Event 'CHECK' @{ check='bootstrap_mast_account'; user=$MastUser }
    if (-not (Get-LocalUser -Name $MastUser -ErrorAction SilentlyContinue)) {
        throw "Local account '$MastUser' not found. Run client\bootstrap-winrm.ps1 first (it creates the mast admin and enables WinRM)."
    }
    Log-Event 'CHECK_OK' @{ check='bootstrap_mast_account' }

    Log-Event 'CHECK' @{ check='bootstrap_winrm_http' }
    $winrmTcp = Test-NetConnection -ComputerName '127.0.0.1' -Port 5985 -WarningAction SilentlyContinue
    if (-not $winrmTcp.TcpTestSucceeded) {
        throw "WinRM HTTP (TCP 5985) is not listening. Run client\bootstrap-winrm.ps1 first."
    }
    Log-Event 'CHECK_OK' @{ check='bootstrap_winrm_http' }

    Log-Event 'CHECK' @{ check='prov_reachable'; ip=$ProvServer }
    $tcp = Test-NetConnection -ComputerName $ProvServer -Port 5985 -WarningAction SilentlyContinue
    if (-not $tcp.PingSucceeded) {
        Log-Event 'CHECK_WARN' @{ check='prov_ping'; reason='not_pingable_but_continuing' }
    }
    Log-Event 'CHECK_OK' @{ check='prov_reachable' }
}

# ---------------------------------------------------------------------------
# Stage 1 - PROVISION  (trigger check-and-provision.ps1 on the prov server)
# ---------------------------------------------------------------------------
function Stage-Provision {
    if (-not $script:ProvSession) {
        # PREFLIGHT does not open the prov-server session; open it here.
        $script:ProvSession = New-PSSession -ComputerName $ProvServer -Authentication Negotiate
        Mirror-ToProvServer -Line "[$(Now-Utc)] PROVISION start  unit=$HostName  (mirroring active)"
    }
    Log-Event 'ACTION' @{ step='trigger_remote_provision'; prov=$ProvServer }
    $modulesArg = if ($Modules) { $Modules -join ',' } else { '' }
    $rc = Invoke-Command -Session $script:ProvSession -ScriptBlock {
        param($hostname, $modulesArg)
        $repo = 'C:\mast-prov\MAST_provisioning'  # convention: prov server has the repo here
        if (-not (Test-Path $repo)) {
            throw "Prov server repo not found at $repo"
        }
        $script = Join-Path $repo 'server\check-and-provision.ps1'
        $args = @('-OnlyHosts', $hostname, '-Force')
        if ($modulesArg) { $args += @('-Modules', $modulesArg) }
        & $script @args
        return $LASTEXITCODE
    } -ArgumentList $HostName, $modulesArg
    if ([int]$rc -ne 0) {
        throw "Remote check-and-provision.ps1 returned exit code $rc"
    }
    Log-Event 'ACTION_OK' @{ step='trigger_remote_provision'; exit_code=0 }
}

# ---------------------------------------------------------------------------
# Stage 2 - REGISTER  (add this unit to prov server's unit-registry.json)
# ---------------------------------------------------------------------------
function Stage-Register {
    if (-not $script:ProvSession) {
        $script:ProvSession = New-PSSession -ComputerName $ProvServer -Authentication Negotiate
    }
    Log-Event 'ACTION' @{ step='register_unit' }
    $myIp = (Get-NetIPAddress -AddressFamily IPv4 |
                Where-Object { $_.IPAddress -notmatch '^127\.|^169\.254' } |
                Select-Object -First 1).IPAddress
    $registerModules = if ($Modules) { $Modules } else { @() }
    Invoke-Command -Session $script:ProvSession -ScriptBlock {
        param($hostname, $ip, $modules)
        $registryPath = 'C:\mast-prov\MAST_provisioning\server\unit-registry.json'
        if (Test-Path $registryPath) {
            $units = Get-Content $registryPath -Raw | ConvertFrom-Json
            $units = @($units | Where-Object { -not $_._comment })
            $units = $units | Where-Object { $_.hostname -ne $hostname }
        } else {
            $units = @()
        }
        $entry = [pscustomobject]@{
            hostname = $hostname
            ip       = $ip
            modules  = $modules
        }
        $newUnits = @($units) + @($entry)
        $tmp = "$registryPath.tmp"
        ($newUnits | ConvertTo-Json -Depth 4) | Out-File -FilePath $tmp -Encoding UTF8
        Move-Item -Force $tmp $registryPath
    } -ArgumentList $HostName, $myIp, $registerModules
    Log-Event 'ACTION_OK' @{ step='register_unit'; ip=$myIp }
}

# ---------------------------------------------------------------------------
# Stage 3 - HANDOFF  (mark available, ready for autonomous loop)
# ---------------------------------------------------------------------------
function Stage-Handoff {
    Log-Event 'ACTION' @{ step='write_availability_true' }
    # available:true writes do not carry expected_return_utc/lease_owner
    # (the unit is in steady state, not under a lease). Route through the
    # shared atomic writer so all availability.json writers share one path.
    $a = [ordered]@{
        available = $true
        since_utc = (Now-Utc)
        reason    = 'onboarding_complete'
    }
    Write-MastStatusFileAtomic -Path (Get-MastAvailabilityPath) -Object $a
    Log-Event 'ACTION_OK' @{ step='write_availability_true' }

    Log-Event 'ACTION' @{ step='cleanup_prov_session' }
    if ($script:ProvSession) {
        Remove-PSSession $script:ProvSession -ErrorAction SilentlyContinue
        $script:ProvSession = $null
    }
    Log-Event 'ACTION_OK' @{ step='cleanup_prov_session' }
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
$stages = @(
    @{ Index=0; Name='PREFLIGHT'; Action={ Stage-Preflight } }
    @{ Index=1; Name='PROVISION'; Action={ Stage-Provision } }
    @{ Index=2; Name='REGISTER';  Action={ Stage-Register  } }
    @{ Index=3; Name='HANDOFF';   Action={ Stage-Handoff   } }
)

if ($ResumeFrom -lt 0) {
    $cp = Read-Checkpoint
    $resume = [int]$cp.last_completed_stage + 1
} else {
    $resume = $ResumeFrom
}

Log-Event 'ONBOARD_START' @{ unit=$HostName; prov=$ProvServer; resume_from=$resume; dry_run=$DryRun.IsPresent }
$onboardStart = Get-Date

try {
    foreach ($stg in $stages) {
        if ($stg.Index -lt $resume) {
            Log-Event 'STAGE_SKIP' @{ stage=$stg.Index; name=$stg.Name; reason='already_completed' }
            continue
        }
        Run-Stage -Index $stg.Index -Name $stg.Name -Action $stg.Action
    }
    $totalDur = [int]((Get-Date) - $onboardStart).TotalSeconds
    Log-Event 'ONBOARD_OK' @{ unit=$HostName; total_duration_s=$totalDur }
    exit 0
}
catch {
    $err = "$($_.Exception.GetType().Name): $($_.Exception.Message)"
    Log-Event 'ONBOARD_FAIL' @{ unit=$HostName; error=$err }
    Write-Host ""
    Write-Host "Onboarding failed. To resume from the failed stage:" -ForegroundColor Yellow
    Write-Host "  .\onboard-mast-unit.ps1 -HostName $HostName -ProvServer $ProvServer -ResumeFrom <stage>" -ForegroundColor Yellow
    exit 1
}
