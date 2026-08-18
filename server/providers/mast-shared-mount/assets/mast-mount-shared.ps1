<#
Maps the unit's operational shared drive Z: -> \\<controller_host>\<share> in the
LOCAL SYSTEM logon session, and records the outcome as JSON.

WHY SYSTEM: the MAST services (mast-unit, mast-phd2, mast-pwi4, mast-pwshutter)
are installed by nssm with no ObjectName, so they run as LocalSystem. Windows
drive letters are per-logon-session, and every LocalSystem process shares one
session -- so a mapping made by an interactive user (or by provisioning, which
runs as the autologon 'mast' user) is INVISIBLE to the services. MAST_common's
Filer probes is_windows_drive_mapped('Z:') from inside mast-unit and silently
falls back to C:\MAST when the probe fails; that fallback is what made the
2026-07-14 exposures look lost. This script therefore runs from a SYSTEM
scheduled task at boot -- see MAST_provisioning issue #25.

Also ensures the per-host directory Filer roots on (Z:\MAST\<hostname>\) exists:
Filer's accessible_shared_root() tests that exact directory, so an empty share
would fall back to C: even with Z: mapped correctly.

Idempotent: an already-correct, reachable mapping is left alone.
ASCII-only; Windows PowerShell 5.1 safe.
#>
# CredCfg is a PATH to a JSON file naming the share account, not a password --
# the rule matches on the parameter's name. See the comment on it below.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredCfg',
    Justification = 'CredCfg is a file path, not a credential; flagged on the name alone.')]
[CmdletBinding()]
param(
    [string]${ConfigPath} = 'C:\WIS\config.toml',
    [string]${BlobPath}   = 'C:\MAST\status\shared-cred.dpapi',
    # {"user": "..."} written beside the blob by the driver -- the account the share
    # accepts. Not a secret, but kept with the credential so the two cannot drift.
    [string]${CredCfg}    = 'C:\MAST\status\shared-cred.json',
    [string]${StatusPath} = 'C:\MAST\status\shared-mount.json',
    [string]${ShareName}  = 'mast-share',
    [string]${User}       = 'mast',
    [string]${Letter}     = 'Z'
)

${ErrorActionPreference} = 'Continue'

${statusDir} = Split-Path -Parent ${StatusPath}
${null} = New-Item -ItemType Directory -Force -Path ${statusDir} -ErrorAction SilentlyContinue

function Write-MountStatus {
    param([bool]${Ok}, [string]${Target}, [string]${Actual}, [string]${Detail})
    ${obj} = @{
        ok          = ${Ok}
        target      = ${Target}
        actual      = ${Actual}
        detail      = ${Detail}
        letter      = ${Letter}
        whoami      = ("{0}\{1}" -f ${env:USERDOMAIN}, ${env:USERNAME})
        checked_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    ${tmp} = "${StatusPath}.tmp"
    [System.IO.File]::WriteAllText(${tmp}, (${obj} | ConvertTo-Json -Compress),
        (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Force ${tmp} ${StatusPath}
    if (${Ok}) { Write-Output ("SHARED_MOUNT_OK {0}" -f ${Target}) }
    else       { Write-Output ("SHARED_MOUNT_FAIL {0}: {1}" -f ${Target}, ${Detail}) }
}

# --- resolve the controller host from the bootstrap config -------------------
# config-bootstrap (order 150) deploys sites/<site>.toml here; controller_host is
# cross-checked against the DB 'sites' document at unit startup, so it is the one
# place that knows which control machine this unit belongs to. No TOML parser
# ships with PS 5.1; the key is a plain quoted scalar.
if (-not (Test-Path -LiteralPath ${ConfigPath})) {
    Write-MountStatus -Ok $false -Target '' -Actual '' -Detail ("config not found: {0}" -f ${ConfigPath})
    exit 1
}
${controller} = ''
foreach (${line} in (Get-Content -LiteralPath ${ConfigPath})) {
    if (${line} -match '^\s*controller_host\s*=\s*"([^"]+)"') { ${controller} = ${Matches}[1]; break }
}
if (-not ${controller}) {
    Write-MountStatus -Ok $false -Target '' -Actual '' -Detail ("controller_host not set in {0}" -f ${ConfigPath})
    exit 1
}

${target}  = "\\{0}\{1}" -f ${controller}, ${ShareName}
${root}    = "{0}:" -f ${Letter}
${hostDir} = "{0}\MAST\{1}" -f ${root}, ${env:COMPUTERNAME}.ToLower()

# --- already mapped correctly? ----------------------------------------------
${current} = ''
${drive} = Get-PSDrive -Name ${Letter} -ErrorAction SilentlyContinue
if (${drive}) { ${current} = [string]${drive}.DisplayRoot }
if (${current} -eq ${target} -and (Test-Path -LiteralPath ("{0}\" -f ${root}))) {
    ${null} = New-Item -ItemType Directory -Force -Path ${hostDir} -ErrorAction SilentlyContinue
    Write-MountStatus -Ok $true -Target ${target} -Actual ${current} -Detail 'already mapped'
    exit 0
}

# Anything else on the letter (a stale prov-server mapping, an unreachable
# pre-rename controller) is wrong by definition -- the letter means one thing.
if (${current}) {
    Write-Output ("Dropping stale {0} -> {1}" -f ${root}, ${current})
    & cmd.exe /c "net use ${root} /delete /yes >nul 2>&1"
}

# --- credential --------------------------------------------------------------
# The share is `valid users = mast`, `guest ok = no`, so the machine account
# cannot authenticate; the password is a machine-bound DPAPI-LocalMachine blob
# written by the provisioning driver (never plaintext on disk).
if (-not (Test-Path -LiteralPath ${BlobPath})) {
    Write-MountStatus -Ok $false -Target ${target} -Actual '' -Detail ("credential blob missing: {0}" -f ${BlobPath})
    exit 1
}
if (Test-Path -LiteralPath ${CredCfg}) {
    ${cc} = Get-Content -LiteralPath ${CredCfg} -Raw | ConvertFrom-Json
    if (${cc}.user) { ${User} = [string]${cc}.user }
}

Add-Type -AssemblyName System.Security
${pass} = ''
try {
    ${enc} = [System.IO.File]::ReadAllBytes(${BlobPath})
    ${dec} = [System.Security.Cryptography.ProtectedData]::Unprotect(
        ${enc}, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    ${pass} = [System.Text.Encoding]::UTF8.GetString(${dec})
} catch {
    Write-MountStatus -Ok $false -Target ${target} -Actual '' -Detail ("blob decrypt failed: {0}" -f $_.Exception.Message)
    exit 1
}

# --- map ---------------------------------------------------------------------
# /persistent:no on purpose: persistent reconnect is a per-user profile feature
# restored at interactive logon, which is exactly what does NOT happen for a
# service account. The boot task re-establishes the mapping instead.
# Password first, then /user: -- net use is position-sensitive (see CLAUDE.md).
${netOut} = & net use ${root} ${target} ${pass} ("/user:{0}" -f ${User}) '/persistent:no' 2>&1
${netRc}  = $LASTEXITCODE
${pass}   = ''
if (${netRc} -ne 0) {
    Write-MountStatus -Ok $false -Target ${target} -Actual '' -Detail ("net use rc={0}: {1}" -f ${netRc}, ((${netOut} | Out-String).Trim()))
    exit 1
}

${null} = New-Item -ItemType Directory -Force -Path ${hostDir} -ErrorAction SilentlyContinue
if (-not (Test-Path -LiteralPath ${hostDir})) {
    Write-MountStatus -Ok $false -Target ${target} -Actual ${target} -Detail ("mapped but could not create {0}" -f ${hostDir})
    exit 1
}

Write-MountStatus -Ok $true -Target ${target} -Actual ${target} -Detail ("mapped; host dir {0}" -f ${hostDir})
exit 0
