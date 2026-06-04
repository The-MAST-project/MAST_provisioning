#requires -Version 5.1
<#
.SYNOPSIS
  Pull a staging payload from the provisioning server's SMB share to the unit.

.DESCRIPTION
  Runs ON THE UNIT (sent via Invoke-Command -FilePath or as an inline scriptblock).
  Mounts \\<ProvServer>\mast-staging with explicit SMB credentials, copies the
  payload with robocopy, then unmounts. Removes stale run dirs and validates
  free space BEFORE pulling, so a large payload cannot fill the unit disk.

  Returns a [pscustomobject] with fields:
    outcome  - 'OK', 'NET_USE_FAIL', 'ROBOCOPY_ERROR', or 'DISK_INSUFFICIENT'
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

function Get-RobocopyOutcome {
    # robocopy exit codes are a bitmask; >=8 means at least one file/dir copy
    # FAILED (errors / retry limit exceeded). 0-7 are success/info. Pure --
    # unit-tested in server/tests/mast-pull-staging.Tests.ps1.
    param([int]$ExitCode)
    if ($ExitCode -ge 8) { 'ROBOCOPY_ERROR' } else { 'OK' }
}

function Test-StagingFits {
    # True if the payload fits on the destination drive with a safety margin.
    # Pure -- unit-tested alongside Get-RobocopyOutcome.
    param([long]$FreeBytes, [long]$PayloadBytes, [long]$MarginBytes = 2GB)
    return ($FreeBytes -ge ([int64]$PayloadBytes + [int64]$MarginBytes))
}

# Dot-sourced with no -SrcUNC (e.g. by the Pester test) -> only the pure
# functions above are needed; skip the live net use / robocopy work below.
if (-not $SrcUNC) { return }

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
    # --- Pre-pull cleanup: remove stale staging payloads BEFORE copying ---
    # Each run dir is large (~tens of GB incl. the astrometry index image). The
    # old post-pull "keep newest 3" never freed space for the CURRENT pull and
    # let payloads pile up (~50 GB), filling the unit disk. Delete all prior run
    # dirs here, before robocopy, so the freed space is usable now. Payloads are
    # disposable: installed software lives in Program Files, not here.
    $stageRoot = Split-Path $UnitStage -Parent
    if (Test-Path $stageRoot) {
        Get-ChildItem $stageRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $UnitStage } |
            ForEach-Object {
                Write-Host "STAGING_CLEANUP_REMOVE $($_.Name)"
                Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue
            }
    }

    # --- Disk-space validation (unit) ---
    # Measure the source payload (metadata only -- fast over SMB) and require it
    # to fit with a 2 GB margin. Fail fast with a clear signal rather than letting
    # robocopy partially copy and return rc>=8 on a full disk.
    $srcBytes = (Get-ChildItem -LiteralPath $SrcUNC -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if (-not $srcBytes) { $srcBytes = 0 }
    $destQual = Split-Path $UnitStage -Qualifier
    $drive = Get-PSDrive -Name ($destQual.TrimEnd(':')) -ErrorAction SilentlyContinue
    if ($drive) {
        $requiredBytes = [int64]$srcBytes + 2GB
        Write-Host ("DISK_CHECK dest={0} freeGB={1:N1} payloadGB={2:N1} requiredGB={3:N1}" -f $destQual, ($drive.Free/1GB), ($srcBytes/1GB), ($requiredBytes/1GB))
        if (-not (Test-StagingFits -FreeBytes $drive.Free -PayloadBytes $srcBytes)) {
            Write-Host ("DISK_INSUFFICIENT freeGB={0:N1} requiredGB={1:N1}" -f ($drive.Free/1GB), ($requiredBytes/1GB))
            return [pscustomobject]@{
                outcome = 'DISK_INSUFFICIENT'
                rc      = -2
                detail  = ("unit drive {0} has {1:N1} GB free; staging payload needs {2:N1} GB (+2 GB margin). Free space and retry." -f $destQual, ($drive.Free/1GB), ($requiredBytes/1GB))
            }
        }
    } else {
        Write-Host "DISK_CHECK skipped (could not resolve drive $destQual)"
    }

    # robocopy creates $UnitStage if absent.
    # /E      - include subdirs (empty too)
    # /R:3 /W:5 - 3 retries, 5s wait per file
    # /NP /NFL /NDL - suppress progress/file/dir noise over WinRM
    Write-Host "ROBOCOPY_START src=$SrcUNC dst=$UnitStage"
    $rbOut = & robocopy $SrcUNC $UnitStage /E /R:3 /W:5 /NP /NFL /NDL 2>&1
    $rbRc  = $LASTEXITCODE
    $rbSummary = ($rbOut | Select-Object -Last 8 | Out-String).Trim()

    $outcome = Get-RobocopyOutcome -ExitCode $rbRc
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
