#requires -Version 5.1
<#
.SYNOPSIS
  Pull a staging payload from the provisioning server's SMB share to the unit.

.DESCRIPTION
  Runs ON THE UNIT (sent via Invoke-Command -FilePath or as an inline scriptblock).
  Mounts \\<ProvServer>\mast-staging with explicit SMB credentials, copies the
  payload with robocopy, then unmounts. Cleans up old run dirs (keeps newest 3).

  Returns a [pscustomobject] with fields:
    outcome  - 'OK', 'NET_USE_FAIL', or 'ROBOCOPY_ERROR'
    rc       - net use or robocopy exit code
    detail   - trimmed output for logging

.PARAMETER ProvServer
  Hostname of the provisioning server (SMB host).

.PARAMETER UnitHostname
  Hostname being provisioned (used in the source UNC path).

.PARAMETER SmbUser
  Username for the read-only SMB account on the provisioning server.

.PARAMETER SmbPass
  Password for the SMB account. Caller must ensure it contains no shell-special chars.

.PARAMETER UnitStage
  Destination path on this machine (the unit), e.g. C:\mast-staging\run-20260513-220000.

.PARAMETER SrcUNC
  Full UNC source path, e.g. \\provserver\mast-staging\mast01\01-provisioning.
#>
param(
    [string]$ProvServer,
    [string]$UnitHostname,
    [string]$SmbUser,
    [string]$SmbPass,
    [string]$UnitStage,
    [string]$SrcUNC
)

$smbRoot = "\\$ProvServer\mast-staging"

<#
Bounded `net use`: when the host SMB server is misconfigured (e.g. the
RejectUnencryptedAccess / EncryptData mismatch we hit 2026-05-25), `net use`
never returns and retries fork-bomb into zombie net.exe processes. Wrap each
invocation in Start-Job + Wait-Job so we fail fast with a meaningful rc.
#>
function Invoke-NetUseBounded {
    param([string[]]$ArgsList, [int]$TimeoutSeconds = 30, [string]$Label = 'net use')
    $j = Start-Job { param($a) $o = & net.exe @a 2>&1; @{rc=$LASTEXITCODE; out=($o|Out-String)} } -ArgumentList (,$ArgsList)
    if (-not (Wait-Job $j -Timeout $TimeoutSeconds)) {
        Stop-Job $j -ErrorAction SilentlyContinue
        Remove-Job $j -Force -ErrorAction SilentlyContinue
        return @{ rc=-1; out="$Label hung ${TimeoutSeconds}s (host SMB misconfigured?)"; hung=$true }
    }
    $r = Receive-Job $j
    Remove-Job $j -Force -ErrorAction SilentlyContinue
    $r.hung = $false
    return $r
}

[void](Invoke-NetUseBounded -ArgsList @('use', $smbRoot, '/delete', '/yes') -TimeoutSeconds 10 -Label 'net use /delete (cleanup)')

Write-Host "NET_USE_ATTEMPT user=$SmbUser share=$smbRoot"
$mountArgs = @('use', $smbRoot, $SmbPass, "/user:$SmbUser", '/persistent:no')
$mount = Invoke-NetUseBounded -ArgsList $mountArgs -TimeoutSeconds 30 -Label 'net use (mount)'
if ($mount.rc -ne 0) {
    Write-Host "NET_USE_RETRY (rc=$($mount.rc)) waiting 10s..."
    Start-Sleep -Seconds 10
    $mount = Invoke-NetUseBounded -ArgsList $mountArgs -TimeoutSeconds 30 -Label 'net use (mount retry)'
}
if ($mount.rc -ne 0) {
    Write-Host "NET_USE_FAIL rc=$($mount.rc)"
    return [pscustomobject]@{
        outcome = $(if ($mount.hung) { 'NET_USE_HUNG' } else { 'NET_USE_FAIL' })
        rc      = $mount.rc
        detail  = $mount.out.Trim()
    }
}
Write-Host "NET_USE_OK output=$($mount.out.Trim())"

try {
    # robocopy creates $UnitStage if absent.
    # /E      - include subdirs (empty too)
    # /R:3 /W:5 - 3 retries, 5s wait per file
    # /NP /NFL /NDL - suppress progress/file/dir noise over WinRM
    Write-Host "ROBOCOPY_START src=$SrcUNC dst=$UnitStage"
    $rbOut = & robocopy $SrcUNC $UnitStage /E /R:3 /W:5 /NP /NFL /NDL 2>&1
    $rbRc  = $LASTEXITCODE
    $rbSummary = ($rbOut | Select-Object -Last 8 | Out-String).Trim()

    # Best-effort cleanup: keep newest 3 run dirs.
    $stageRoot = Split-Path $UnitStage -Parent
    if (Test-Path $stageRoot) {
        Get-ChildItem $stageRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 3 |
            ForEach-Object {
                Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue
            }
    }

    $outcome = $(if ($rbRc -ge 8) { 'ROBOCOPY_ERROR' } else { 'OK' })
    Write-Host "ROBOCOPY_DONE rc=$rbRc outcome=$outcome"
    Write-Host "ROBOCOPY_SUMMARY $rbSummary"
    return [pscustomobject]@{
        outcome = $outcome
        rc      = $rbRc
        detail  = $rbSummary
    }
} finally {
    # Always unmount, even if robocopy failed.
    [void](Invoke-NetUseBounded -ArgsList @('use', $smbRoot, '/delete', '/yes') -TimeoutSeconds 10 -Label 'net use /delete (final)')
    Write-Host "NET_USE_DISCONNECTED"
}
