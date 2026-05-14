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

# Remove stale mapping from any previous crashed run (ignore errors).
& net use $smbRoot /delete /yes 2>&1 | Out-Null

# Mount share with explicit credentials (workgroup -- no Kerberos).
# /persistent:no avoids storing credentials on the unit.
Write-Host "NET_USE_ATTEMPT user=$SmbUser share=$smbRoot"
$netOut = & net use $smbRoot $SmbPass /user:$SmbUser /persistent:no 2>&1
$netRc  = $LASTEXITCODE
if ($netRc -ne 0) {
    Write-Host "NET_USE_RETRY (rc=$netRc) waiting 10s..."
    Start-Sleep -Seconds 10
    $netOut = & net use $smbRoot $SmbPass /user:$SmbUser /persistent:no 2>&1
    $netRc  = $LASTEXITCODE
}
if ($netRc -ne 0) {
    Write-Host "NET_USE_FAIL rc=$netRc"
    return [pscustomobject]@{
        outcome = 'NET_USE_FAIL'
        rc      = $netRc
        detail  = ($netOut | Out-String).Trim()
    }
}
Write-Host "NET_USE_OK output=$(($netOut | Out-String).Trim())"

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
    & net use $smbRoot /delete /yes 2>&1 | Out-Null
    Write-Host "NET_USE_DISCONNECTED"
}
