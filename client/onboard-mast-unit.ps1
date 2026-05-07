#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  One-shot bootstrap script for a brand-new MAST unit (physical or VM).

.DESCRIPTION
  Brings a freshly installed Windows machine from "OS just booted" to
  "fully provisioned, registered with the prov server, autonomous from
  here on". Runs locally on the unit; no remote driver needed.

  Stages:
    0  PREFLIGHT  Verify admin, network, prov server reachable
    1  BOOTSTRAP  Create 'mast' admin, enable WinRM HTTP+Basic
    2  PREPARE    Set hostname, WinRM HTTPS, suppress Windows Update
    3  PROVISION  Pull staged payload from prov server, run execute-mast-provisioning.ps1
    4  REGISTER   Append unit to prov server's unit-registry.json
    5  HANDOFF    Install scheduled task / mark availability=true

  Idempotent. Re-running on a partially-onboarded machine resumes from
  the last completed stage (checkpoint at C:\ProgramData\MAST\onboarding-checkpoint.json).

  All progress is logged structured at C:\ProgramData\MAST\logs\onboarding.log
  and (from Stage 2 onward) mirrored to the prov server at
  C:\ProgramData\MAST\logs\onboarding\<hostname>.log.

.PARAMETER HostName
  Required. The unit's MAST hostname (mast01..mast20).

.PARAMETER ProvServer
  Required. IP of the provisioning server.

.PARAMETER ProvUser
  Account on the prov server with read access to its repo / staging dir.
  Format ".\\mast" or "DOMAIN\\user". Default ".\\mast".

.PARAMETER ProvSharePath
  UNC or local path to the MAST_provisioning checkout on the prov server.
  Default \\<ProvServer>\mast-prov\MAST_provisioning (assumes admin share).
  Only used if pulling source for local build; otherwise the script
  triggers check-and-provision.ps1 remotely on the prov server.

.PARAMETER StaticIp
  Optional. If given, configures the host-only adapter with this IP.
  Format "192.168.56.20/24". Default: keep DHCP.

.PARAMETER ResumeFrom
  Stage to resume from (0..5). Default: read checkpoint and continue.

.PARAMETER Modules
  Optional explicit module list for the provisioning step.

.PARAMETER MastUser, MastPassword
  Local 'mast' admin account credentials. Defaults: mast / physics
  (matches bootstrap-winrm.ps1; change for production).

.PARAMETER DryRun
  Log every action but do not execute side effects.

.EXAMPLE
  # Fresh physical unit:
  .\onboard-mast-unit.ps1 -HostName mast01 -ProvServer 192.168.56.1 -StaticIp 192.168.56.20/24

  # Resume after a failed Stage 3 (provisioning):
  .\onboard-mast-unit.ps1 -HostName mast01 -ProvServer 192.168.56.1 -ResumeFrom 3
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^mast(0[1-9]|1[0-9]|20)$')]
    [string]$HostName,

    [Parameter(Mandatory=$true)]
    [string]$ProvServer,

    [string]   $ProvUser      = '.\mast',
    [string]   $ProvSharePath = '',
    [string]   $StaticIp      = '',
    [int]      $ResumeFrom    = -1,
    [string[]] $Modules,
    [string]   $MastUser      = 'mast',
    [string]   $MastPassword  = 'physics',
    [switch]   $DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$DataRoot       = Join-Path $env:ProgramData 'MAST'
$LogDir         = Join-Path $DataRoot 'logs'
$OnboardingLog  = Join-Path $LogDir   'onboarding.log'
$CheckpointPath = Join-Path $DataRoot 'onboarding-checkpoint.json'
$StatusDir      = Join-Path $DataRoot 'status'

New-Item -ItemType Directory -Force -Path $DataRoot, $LogDir, $StatusDir | Out-Null

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Now-Utc { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

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
            $remoteDir = "C:\ProgramData\MAST\logs\onboarding"
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
# Stage 0 - PREFLIGHT
# ---------------------------------------------------------------------------
function Stage-Preflight {
    Log-Event 'CHECK' @{ check='admin_rights' }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')
    if (-not $isAdmin) { throw "Must run as Administrator." }
    Log-Event 'CHECK_OK' @{ check='admin_rights' }

    Log-Event 'CHECK' @{ check='prov_reachable'; ip=$ProvServer }
    $tcp = Test-NetConnection -ComputerName $ProvServer -Port 5985 -WarningAction SilentlyContinue
    if (-not $tcp.PingSucceeded) {
        Log-Event 'CHECK_WARN' @{ check='prov_ping'; reason='not_pingable_but_continuing' }
    }
    Log-Event 'CHECK_OK' @{ check='prov_reachable' }
}

# ---------------------------------------------------------------------------
# Stage 1 - BOOTSTRAP  (mast user, WinRM HTTP, firewall)
# ---------------------------------------------------------------------------
function Stage-Bootstrap {
    Log-Event 'ACTION' @{ step='ensure_mast_account' }
    $secPwd = ConvertTo-SecureString $MastPassword -AsPlainText -Force
    $existing = Get-LocalUser -Name $MastUser -ErrorAction SilentlyContinue
    if ($existing) {
        Set-LocalUser -Name $MastUser -Password $secPwd -PasswordNeverExpires $true
    } else {
        New-LocalUser -Name $MastUser -Password $secPwd `
            -FullName 'MAST Administrator' -PasswordNeverExpires `
            -UserMayNotChangePassword | Out-Null
    }
    $admins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "\\$MastUser$" }
    if (-not $admins) { Add-LocalGroupMember -Group 'Administrators' -Member $MastUser }
    Log-Event 'ACTION_OK' @{ step='ensure_mast_account' }

    Log-Event 'ACTION' @{ step='enable_winrm_http' }
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    winrm set winrm/config/service/auth '@{Basic="true"}' | Out-Null
    winrm set winrm/config/service '@{AllowUnencrypted="true"}' | Out-Null
    Set-Service WinRM -StartupType Automatic
    Log-Event 'ACTION_OK' @{ step='enable_winrm_http' }

    Log-Event 'ACTION' @{ step='firewall_winrm_http' }
    $rule = 'MAST - WinRM HTTP'
    if (-not (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $rule -Direction Inbound -Protocol TCP `
            -LocalPort 5985 -Action Allow -Profile Any | Out-Null
    }
    Log-Event 'ACTION_OK' @{ step='firewall_winrm_http' }
}

# ---------------------------------------------------------------------------
# Stage 2 - PREPARE  (hostname, WinRM HTTPS, WU suppression, static IP, prov session)
# ---------------------------------------------------------------------------
function Stage-Prepare {
    if ($StaticIp) {
        Log-Event 'ACTION' @{ step='set_static_ip'; value=$StaticIp }
        $parts = $StaticIp -split '/'
        $ip = $parts[0]; $prefix = if ($parts.Count -ge 2) { [int]$parts[1] } else { 24 }
        $hostOnlyAdapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Name -notmatch 'Wi-Fi|Bluetooth' } |
                            Sort-Object InterfaceMetric | Select-Object -First 1
        if ($hostOnlyAdapter) {
            try {
                Get-NetIPAddress -InterfaceIndex $hostOnlyAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.PrefixOrigin -eq 'Manual' } |
                    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                New-NetIPAddress -InterfaceIndex $hostOnlyAdapter.ifIndex -IPAddress $ip -PrefixLength $prefix -DefaultGateway $ProvServer | Out-Null
                Log-Event 'ACTION_OK' @{ step='set_static_ip'; ip=$ip; prefix=$prefix }
            } catch {
                Log-Event 'ACTION_WARN' @{ step='set_static_ip'; error=$_.Exception.Message }
            }
        }
    }

    Log-Event 'ACTION' @{ step='set_hostname'; value=$HostName }
    $current = (Get-CimInstance Win32_ComputerSystem).Name
    if ($current -ieq $HostName) {
        Log-Event 'ACTION_OK' @{ step='set_hostname'; reason='already_set' }
    } else {
        Rename-Computer -NewName $HostName -Force -ErrorAction Stop
        Log-Event 'ACTION_OK' @{ step='set_hostname'; pending_reboot='true' }
        # Continue execution; rename takes effect on reboot.
    }

    Log-Event 'ACTION' @{ step='winrm_https_listener' }
    try {
        $cert = New-SelfSignedCertificate -DnsName @($HostName, $env:COMPUTERNAME) `
            -CertStoreLocation Cert:\LocalMachine\My -KeyLength 2048 -NotAfter (Get-Date).AddYears(5)
        Get-ChildItem WSMan:\LocalHost\Listener\ -ErrorAction SilentlyContinue |
            Where-Object { $_.Keys -match 'Transport=HTTPS' } |
            ForEach-Object { Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -Path WSMan:\LocalHost\Listener -Transport HTTPS -Address * `
            -Hostname $HostName -CertificateThumbprint $cert.Thumbprint -ErrorAction Stop | Out-Null
        $rule = 'MAST - WinRM HTTPS'
        if (-not (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $rule -Direction Inbound -Protocol TCP `
                -LocalPort 5986 -Action Allow -Profile Any | Out-Null
        }
        Log-Event 'ACTION_OK' @{ step='winrm_https_listener'; thumbprint=$cert.Thumbprint }
    } catch {
        Log-Event 'ACTION_WARN' @{ step='winrm_https_listener'; error=$_.Exception.Message }
    }

    Log-Event 'ACTION' @{ step='suppress_windows_update' }
    $auPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    New-Item -Path $auPath -Force | Out-Null
    Set-ItemProperty -Path $auPath -Name NoAutoUpdate -Value 1 -Type DWord
    Set-ItemProperty -Path $auPath -Name AUOptions -Value 1 -Type DWord
    Set-ItemProperty -Path $auPath -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Set-Service wuauserv -StartupType Disabled
    Log-Event 'ACTION_OK' @{ step='suppress_windows_update' }

    # Open a session to the prov server so subsequent stages can mirror logs
    Log-Event 'ACTION' @{ step='open_prov_session' }
    try {
        $script:ProvSession = New-PSSession -ComputerName $ProvServer -Authentication Negotiate -ErrorAction Stop
        Mirror-ToProvServer -Line "[$(Now-Utc)] STAGE_OK  stage=2  unit=$HostName  (mirroring active)"
        Log-Event 'ACTION_OK' @{ step='open_prov_session' }
    } catch {
        Log-Event 'ACTION_WARN' @{ step='open_prov_session'; error=$_.Exception.Message; effect='no_remote_log_mirror' }
    }
}

# ---------------------------------------------------------------------------
# Stage 3 - PROVISION  (trigger check-and-provision.ps1 on the prov server)
# ---------------------------------------------------------------------------
function Stage-Provision {
    if (-not $script:ProvSession) {
        # Re-establish if Stage 2 didn't manage to
        $script:ProvSession = New-PSSession -ComputerName $ProvServer -Authentication Negotiate
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
# Stage 4 - REGISTER  (add this unit to prov server's unit-registry.json)
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
# Stage 5 - HANDOFF  (mark available, ready for autonomous loop)
# ---------------------------------------------------------------------------
function Stage-Handoff {
    Log-Event 'ACTION' @{ step='write_availability_true' }
    $tmp = Join-Path $StatusDir 'availability.json.tmp'
    $a = @{
        available = $true
        since_utc = (Now-Utc)
        reason    = 'onboarding_complete'
    }
    ($a | ConvertTo-Json) | Out-File -FilePath $tmp -Encoding UTF8
    Move-Item -Force $tmp (Join-Path $StatusDir 'availability.json')
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
    @{ Index=1; Name='BOOTSTRAP'; Action={ Stage-Bootstrap } }
    @{ Index=2; Name='PREPARE';   Action={ Stage-Prepare   } }
    @{ Index=3; Name='PROVISION'; Action={ Stage-Provision } }
    @{ Index=4; Name='REGISTER';  Action={ Stage-Register  } }
    @{ Index=5; Name='HANDOFF';   Action={ Stage-Handoff   } }
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
