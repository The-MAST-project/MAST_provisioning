#Requires -Version 5.1
<#
.SYNOPSIS
  One-time elevated setup: create the mast-staging SMB share and mast-transfer account.

.DESCRIPTION
  Run this once on the provisioning server before activating the autonomous loop.
  It creates a read-only local account ('mast-transfer', credentials from
  vault/creds.json) and exposes the staging/ directory as \\<server>\mast-staging
  with least-privilege NTFS and share permissions.

  check-and-provision.ps1 triggers units to pull from this share via robocopy.
  Nothing in the normal provisioning cycle needs to re-run this script.

.PARAMETER Top
  Path to the MAST_provisioning repo root. Defaults to the script's parent directory.

.EXAMPLE
  # Elevated PowerShell on the provisioning server:
  .\server\setup-smb-share.ps1

.EXAMPLE
  # Specify repo root explicitly:
  .\server\setup-smb-share.ps1 -Top C:\repos\MAST_provisioning
#>

[CmdletBinding()]
param(
    [string]$Top = ''
)

$ErrorActionPreference = 'Stop'

if (-not $Top -or [string]::IsNullOrWhiteSpace($Top)) {
    # Script lives at <RepoTop>\server\setup-smb-share.ps1
    $Top = Split-Path -Parent $PSScriptRoot
}

# ---------------------------------------------------------------------------
# Require elevation -- SMB share and local account creation need it.
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent() `
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Restarting elevated..."
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Top `"$Top`""
    Start-Process powershell.exe -ArgumentList $argLine -Verb RunAs -Wait
    exit 0
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$vault    = Join-Path $Top 'vault'
$outRoot  = Join-Path $Top 'staging'

if (-not (Test-Path $outRoot)) {
    New-Item -ItemType Directory -Force -Path $outRoot | Out-Null
    Write-Host "Created staging directory: $outRoot"
}

# ---------------------------------------------------------------------------
# Read SMB transfer credentials from vault
# ---------------------------------------------------------------------------
$vaultCreds = Join-Path $vault 'creds.json'
if (-not (Test-Path $vaultCreds)) {
    throw "vault/creds.json not found at $vaultCreds. Copy vault/creds.json.template and fill in values."
}
$vaultData = Get-Content $vaultCreds -Raw | ConvertFrom-Json
if (-not $vaultData.smb -or -not $vaultData.smb.user -or -not $vaultData.smb.pass) {
    throw "vault/creds.json is missing the 'smb' block. Add smb.user and smb.pass."
}
$smbUser = $vaultData.smb.user
$smbPass = $vaultData.smb.pass

Write-Host "Transfer account: $smbUser"

# ---------------------------------------------------------------------------
# Create / update mast-transfer local account
# ---------------------------------------------------------------------------
$securePw    = ConvertTo-SecureString $smbPass -AsPlainText -Force
$existingUser = Get-LocalUser -Name $smbUser -ErrorAction SilentlyContinue
if (-not $existingUser) {
    Write-Host "Creating local account '$smbUser'..."
    New-LocalUser -Name $smbUser `
                  -Password $securePw `
                  -FullName "MAST Transfer (read-only)" `
                  -Description "Read-only SMB pull account for MAST units" `
                  -PasswordNeverExpires `
                  -UserMayNotChangePassword `
                  -AccountNeverExpires `
                  -ErrorAction Stop | Out-Null
    Write-Host "Created local account '$smbUser'."
} else {
    Write-Host "Account '$smbUser' already exists -- updating password..."
    Set-LocalUser -Name $smbUser -Password $securePw -ErrorAction SilentlyContinue
}

# Remove from Users group (least-privilege hardening).
try {
    Remove-LocalGroupMember -Group "Users" -Member $smbUser -ErrorAction SilentlyContinue
} catch {}

# ---------------------------------------------------------------------------
# SMB share
# ---------------------------------------------------------------------------
# Helper: idempotent SMB share + NTFS ACL setup
# ---------------------------------------------------------------------------
function Ensure-MastSmbShare {
    param(
        [string]$Name,
        [string]$SharePath,
        [string]$Comment,
        [string]$ShareAccess,
        [string]$NtfsAccess,
        [string]$AccountName,
        [System.Security.Principal.SecurityIdentifier]$EveryoneSid
    )

    if (-not (Test-Path $SharePath)) {
        New-Item -ItemType Directory -Force -Path $SharePath | Out-Null
        Write-Host "Created directory: $SharePath"
    }

    $existing = Get-SmbShare -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Share '$Name' already exists at $($existing.Path)"
        if ($existing.Path -ne $SharePath) {
            Write-Warning "Path mismatch ($($existing.Path) vs $SharePath) -- removing and recreating..."
            Remove-SmbShare -Name $Name -Force
            $existing = $null
        }
    }

    if (-not $existing) {
        $shareParams = @{
            Name        = $Name
            Path        = $SharePath
            FullAccess  = @('Administrators', 'SYSTEM')
            Description = $Comment
            ErrorAction = 'Stop'
        }
        if ($ShareAccess -eq 'Read') {
            $shareParams['ReadAccess'] = @($AccountName)
        } else {
            $shareParams['ChangeAccess'] = @($AccountName)
        }
        New-SmbShare @shareParams | Out-Null
        Write-Host "Created SMB share: \\$($env:COMPUTERNAME)\$Name"
    } else {
        Grant-SmbShareAccess  -Name $Name -AccountName $AccountName `
                              -AccessRight $ShareAccess -Force -ErrorAction SilentlyContinue | Out-Null
        Revoke-SmbShareAccess -Name $Name -AccountName 'Everyone' `
                              -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Host "Updated SMB share permissions for '$AccountName' on '$Name'."
    }

    $acl = Get-Acl $SharePath
    $everyoneRules = $acl.Access | Where-Object {
        try {
            $_.IdentityReference.Translate(
                [System.Security.Principal.SecurityIdentifier]
            ).Value -eq $EveryoneSid.Value
        } catch { $false }
    }
    foreach ($r in $everyoneRules) { $acl.RemoveAccessRule($r) | Out-Null }

    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $AccountName,
        $NtfsAccess,
        'ContainerInherit,ObjectInherit',
        'None',
        'Allow'
    )
    $acl.AddAccessRule($rule)
    Set-Acl -Path $SharePath -AclObject $acl
    Write-Host "NTFS ACL: granted $NtfsAccess to '$AccountName' on '$Name', removed Everyone."
}

# Build the Everyone SID once; passed into each Ensure-MastSmbShare call.
$everyoneSid = New-Object System.Security.Principal.SecurityIdentifier(
    [System.Security.Principal.WellKnownSidType]::WorldSid, $null
)

# ---------------------------------------------------------------------------
# mast-staging: read-only pull share for units
# ---------------------------------------------------------------------------
Ensure-MastSmbShare `
    -Name        'mast-staging' `
    -SharePath   $outRoot `
    -Comment     'MAST provisioning staging (read-only pull for units)' `
    -ShareAccess 'Read' `
    -NtfsAccess  'ReadAndExecute' `
    -AccountName $smbUser `
    -EveryoneSid $everyoneSid

# ---------------------------------------------------------------------------
# mast-shared: writable share for unit machines to save files back to the server
# ---------------------------------------------------------------------------
$sharedRoot = Join-Path $Top 'shared'
Ensure-MastSmbShare `
    -Name        'mast-shared' `
    -SharePath   $sharedRoot `
    -Comment     'MAST shared directory (read-write for units)' `
    -ShareAccess 'Change' `
    -NtfsAccess  'Modify' `
    -AccountName $smbUser `
    -EveryoneSid $everyoneSid

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=========================================="
Write-Host "Provisioning share ready:"
Write-Host "  UNC:              \\$($env:COMPUTERNAME)\mast-staging"
Write-Host "  Local path:       $outRoot"
Write-Host "  Transfer account: $smbUser"
Write-Host "  Unit pulls from:  \\$($env:COMPUTERNAME)\mast-staging\<hostname>\01-provisioning"
Write-Host ""
Write-Host "Shared (writable) share ready:"
Write-Host "  UNC:              \\$($env:COMPUTERNAME)\mast-shared"
Write-Host "  Local path:       $sharedRoot"
Write-Host "  Unit maps as:     Z: -> \\$($env:COMPUTERNAME)\mast-shared"
Write-Host "=========================================="
Write-Host "Setup complete. Run install-scheduled-task.ps1 to activate the autonomous loop."
Write-Host "=========================================="
