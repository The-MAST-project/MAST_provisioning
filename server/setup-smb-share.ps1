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
$shareName    = "mast-staging"
$sharePath    = $outRoot
$shareComment = "MAST provisioning staging (read-only pull for units)"

$existingShare = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
if ($existingShare) {
    Write-Host "Share '$shareName' already exists at $($existingShare.Path)"
    if ($existingShare.Path -ne $sharePath) {
        Write-Warning "Path mismatch ($($existingShare.Path) vs $sharePath) -- removing and recreating..."
        Remove-SmbShare -Name $shareName -Force
        $existingShare = $null
    }
}

if (-not $existingShare) {
    New-SmbShare -Name $shareName `
                 -Path $sharePath `
                 -FullAccess @("Administrators", "SYSTEM") `
                 -ReadAccess @($smbUser) `
                 -Description $shareComment `
                 -ErrorAction Stop | Out-Null
    Write-Host "Created SMB share: \\$($env:COMPUTERNAME)\$shareName"
} else {
    Grant-SmbShareAccess  -Name $shareName -AccountName $smbUser `
                          -AccessRight Read -Force -ErrorAction SilentlyContinue | Out-Null
    Revoke-SmbShareAccess -Name $shareName -AccountName "Everyone" `
                          -Force -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Updated SMB share permissions for '$smbUser'."
}

# ---------------------------------------------------------------------------
# NTFS ACL: replace Everyone (if present) with mast-transfer ReadAndExecute
# ---------------------------------------------------------------------------
$acl = Get-Acl $sharePath
$everyoneSid = New-Object System.Security.Principal.SecurityIdentifier(
    [System.Security.Principal.WellKnownSidType]::WorldSid, $null
)
$rulesToRemove = $acl.Access | Where-Object {
    try {
        $_.IdentityReference.Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value -eq $everyoneSid.Value
    } catch { $false }
}
foreach ($r in $rulesToRemove) { $acl.RemoveAccessRule($r) | Out-Null }

$xferRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $smbUser,
    "ReadAndExecute",
    "ContainerInherit,ObjectInherit",
    "None",
    "Allow"
)
$acl.AddAccessRule($xferRule)
Set-Acl -Path $sharePath -AclObject $acl
Write-Host "NTFS ACL: granted ReadAndExecute to '$smbUser', removed Everyone."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=========================================="
Write-Host "Provisioning share ready:"
Write-Host "  UNC:              \\$($env:COMPUTERNAME)\$shareName"
Write-Host "  Local path:       $sharePath"
Write-Host "  Transfer account: $smbUser"
Write-Host "  Unit pulls from:  \\$($env:COMPUTERNAME)\$shareName\<hostname>\01-provisioning"
Write-Host "=========================================="
Write-Host "Setup complete. Run install-scheduled-task.ps1 to activate the autonomous loop."
Write-Host "=========================================="
