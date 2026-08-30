#requires -Version 5.1
[CmdletBinding()]
param(
    [string]${MountScript} = 'C:\MAST\mast-mount-shared.ps1',
    [string]${TaskName}    = 'MAST-Mount-Shared',
    [string]${StatusPath}  = 'C:\MAST\status\shared-mount.json',
    [string]${Letter}      = 'Z'
)

${ErrorActionPreference} = 'Stop'
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off
${verifyLog} = Get-MastVerifyLog -Module 'mast-shared-mount'

function W { param([string]${Line}) Add-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), ${Line}) }
Set-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] verify-mast-shared-mount.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

${fail} = @()

# 1) The mount script is installed where the startup task points.
if (Test-Path -LiteralPath ${MountScript}) {
    W ("mount script present: {0}" -f ${MountScript})
} else {
    ${fail} += ("mount script missing: {0}" -f ${MountScript})
}

# 2) The startup task exists and runs as SYSTEM. The account is the whole point:
# drive letters are per-logon-session and the MAST services run as LocalSystem, so a
# task registered under any interactive user would map the letter where nothing that
# needs it can see it.
${task} = Get-ScheduledTask -TaskName ${TaskName} -ErrorAction SilentlyContinue
if (${task}) {
    ${uid} = [string]${task}.Principal.UserId
    W ("task '{0}' registered (UserId={1}, LogonType={2})" -f ${TaskName}, ${uid}, ${task}.Principal.LogonType)
    if (${uid} -notmatch '(?i)^(SYSTEM|NT AUTHORITY\\SYSTEM|S-1-5-18)$') {
        ${fail} += ("task '{0}' runs as '{1}', expected SYSTEM" -f ${TaskName}, ${uid})
    }
    if (-not (@(${task}.Triggers) | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' })) {
        ${fail} += ("task '{0}' has no at-startup trigger" -f ${TaskName})
    }
} else {
    ${fail} += ("startup task '{0}' not registered" -f ${TaskName})
}

# 3) No per-user mapping of the letter survived. One left behind is what produced the
# fleet-wide ambiguity in the first place (mast00 -> pre-rename controller,
# mast03 -> the provisioning laptop's mast-shared), and it shadows nothing useful.
${userMapKey} = "HKCU:\Network\{0}" -f ${Letter}
if (Test-Path -LiteralPath ${userMapKey}) {
    ${stale} = (Get-ItemProperty -LiteralPath ${userMapKey} -ErrorAction SilentlyContinue).RemotePath
    ${fail} += ("per-user {0}: mapping still present ({1})" -f ${Letter}, ${stale})
} else {
    W ("no per-user {0}: mapping (correct -- the mapping belongs to the SYSTEM session)" -f ${Letter})
}

# 4) Report the last mount outcome. NOT a failure: a unit provisioned away from its
# site cannot reach the controller, and the install is still correct. The record has
# to be visible, though -- a silent unmounted Z: is exactly how exposures ended up on
# C: unnoticed on 2026-07-14.
if (Test-Path -LiteralPath ${StatusPath}) {
    ${status} = Get-Content -LiteralPath ${StatusPath} -Raw | ConvertFrom-Json
    if (${status}.ok) {
        W ("last mount OK: {0} -> {1} ({2})" -f ${Letter}, ${status}.target, ${status}.checked_utc)
    } else {
        W ("[WARN] last mount FAILED: target={0} detail={1} at {2}" -f ${status}.target, ${status}.detail, ${status}.checked_utc)
        W  "[WARN] the unit will write exposures to C:\MAST until the share is reachable."
    }
} else {
    W ("[WARN] no mount status at {0} -- the task has not reported yet." -f ${StatusPath})
}

if (${fail}.Count -gt 0) {
    foreach (${f} in ${fail}) { W ("[FAIL] " + ${f}) }
    Write-Host ("mast-shared-mount verify FAILED: " + (${fail} -join '; '))
    exit 1
}
W 'verify OK'
Write-Host 'mast-shared-mount verify OK'
exit 0
