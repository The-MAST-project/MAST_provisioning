# Host-side SMB pre-flight checks for the MAST provisioning pipeline.
#
# Lives in server/lib/ and is dot-sourceable from anywhere (no admin
# requirement to *read*; the checks themselves do not modify state).
# Dotted by check-and-provision.ps1 (runs before TRANSFER on every cycle)
# and by setup-smb-share.ps1 (runs at end of one-time setup to assert the
# host is actually in a state where units can pull).
#
# Why this exists: on 2026-05-25 a freshly-Windows-Updated host left the
# SMB server with `RejectUnencryptedAccess = True` (a Win11 24H2 default)
# while the mast-staging / mast-shared shares had `EncryptData = False`.
# The net effect was that no remote client could connect: the SMB server
# rejected every non-encrypted session, and the symptom on the unit was
# `net use` hanging or returning a misleading error 67 ("network name
# not found"). The transfer ran for many minutes with no progress before
# we noticed.
#
# The checks below catch every member of that failure family before a
# real transfer attempts to use the broken share.

function Test-MastSmbHostReady {
    [CmdletBinding()]
    param(
        [string[]]$ShareNames    = @('mast-staging', 'mast-shared'),
        [string]  $TransferUser  = '',
        [string]  $TransferPass  = '',
        [switch]  $Quiet
    )

    $failures = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    function _log {
        param([string]$Line)
        if (-not $Quiet) { Write-Host ("[preflight-smb] {0}" -f $Line) }
    }

    # --- 1. LanmanServer service must be running ---
    $svc = Get-Service -Name 'LanmanServer' -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        [void]$failures.Add("LanmanServer service is not installed.")
    } elseif ($svc.Status -ne 'Running') {
        [void]$failures.Add("LanmanServer service is '$($svc.Status)', expected 'Running'.")
    } else {
        _log "LanmanServer: Running"
    }

    # --- 2. SMB server must be bound to at least one network interface ---
    # Empty result here means the server is up but unreachable from any
    # remote client; loopback still works (it bypasses interface binding).
    # NOTE: Get-SmbServerNetworkInterface silently returns nothing for
    # non-elevated callers (no error, just empty), so we can only treat an
    # empty result as a real failure when we *are* elevated. Otherwise we
    # skip with a warning and rely on the loopback auth check below, which
    # works without admin and detects the same class of failure end-to-end.
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole] "Administrator"
    )
    if ($isAdmin) {
        $ifaces = @(Get-SmbServerNetworkInterface -ErrorAction SilentlyContinue)
        if ($ifaces.Count -eq 0) {
            [void]$failures.Add(
                "Get-SmbServerNetworkInterface returned no rows. SMB server has " +
                "no usable interfaces bound -- remote clients will fail to connect " +
                "(loopback may still work). Common cause: a recent Windows update " +
                "changed RejectUnencryptedAccess to True; restart LanmanServer or " +
                "fix the encryption mismatch (next check)."
            )
        } else {
            _log ("SMB bound on {0} interface(s): {1}" -f $ifaces.Count, ($ifaces.IpAddress -join ', '))
        }
    } else {
        [void]$warnings.Add(
            "SMB interface-binding check skipped (process is not elevated; " +
            "Get-SmbServerNetworkInterface returns empty for non-admins). The " +
            "loopback auth check below covers the same failure family."
        )
    }

    # --- 3. RejectUnencryptedAccess vs per-share EncryptData consistency ---
    # When the server rejects unencrypted access but the share is not
    # configured for encryption, every client connection fails. Both
    # settings are local; either tightening (set EncryptData=$true on the
    # share) or loosening (set RejectUnencryptedAccess=$false on the
    # server) closes the gap.
    $srvCfg = Get-SmbServerConfiguration -ErrorAction SilentlyContinue
    if ($null -eq $srvCfg) {
        [void]$failures.Add("Cannot read Get-SmbServerConfiguration.")
    } else {
        _log ("RejectUnencryptedAccess = {0}, server EncryptData = {1}" `
            -f $srvCfg.RejectUnencryptedAccess, $srvCfg.EncryptData)
        if ($srvCfg.RejectUnencryptedAccess) {
            foreach ($sn in $ShareNames) {
                $share = Get-SmbShare -Name $sn -ErrorAction SilentlyContinue
                if ($null -eq $share) {
                    [void]$failures.Add("Required share '$sn' is missing. Run server\setup-smb-share.ps1.")
                    continue
                }
                if (-not $share.EncryptData) {
                    [void]$failures.Add(
                        "Share '$sn' has EncryptData=False, but the server has " +
                        "RejectUnencryptedAccess=True. This combination blocks " +
                        "EVERY remote client. Fix: " +
                        "Set-SmbShare -Name $sn -EncryptData `$true (more secure) " +
                        "OR Set-SmbServerConfiguration -RejectUnencryptedAccess `$false -Force."
                    )
                }
            }
        } else {
            # RejectUnencryptedAccess=False is permissive; still verify shares exist.
            foreach ($sn in $ShareNames) {
                if (-not (Get-SmbShare -Name $sn -ErrorAction SilentlyContinue)) {
                    [void]$failures.Add("Required share '$sn' is missing. Run server\setup-smb-share.ps1.")
                }
            }
        }
    }

    # --- 4. Loopback authentication smoke test (only if creds supplied) ---
    # Catches the case where shares exist + are configured correctly but
    # the transfer account password drifted from what's in vault/creds.json.
    if ($TransferUser -and $TransferPass -and $failures.Count -eq 0) {
        $hostName = $env:COMPUTERNAME
        foreach ($sn in $ShareNames) {
            $unc = "\\$hostName\$sn"
            # Drop any stale loopback mapping first.
            & net use $unc /delete /yes 2>&1 | Out-Null
            $job = Start-Job -ScriptBlock {
                param($u, $p, $user)
                & net use $u $p /user:$user /persistent:no 2>&1
                $rc = $LASTEXITCODE
                @{ output = ($input | Out-String); rc = $rc }
            } -ArgumentList $unc, $TransferPass, $TransferUser
            $finished = Wait-Job $job -Timeout 15
            if (-not $finished) {
                Stop-Job $job -ErrorAction SilentlyContinue
                [void]$failures.Add(
                    "Loopback 'net use $unc' as $TransferUser hung for 15s. " +
                    "This is the symptom remote units hit just before they get stuck."
                )
            } else {
                $r = Receive-Job $job
                if ($r.rc -ne 0 -and $r.rc -ne $null) {
                    [void]$failures.Add(
                        "Loopback 'net use $unc' as $TransferUser returned exit $($r.rc). " +
                        "Auth or share-name mismatch. Output: $($r.output -replace '\s+',' ')"
                    )
                } else {
                    _log ("Loopback auth to {0} as {1}: OK" -f $unc, $TransferUser)
                }
            }
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            & net use $unc /delete /yes 2>&1 | Out-Null
        }
    } elseif (-not $TransferUser -or -not $TransferPass) {
        [void]$warnings.Add("Transfer-account loopback check skipped (no creds supplied).")
    }

    # --- summary ---
    if ($warnings.Count -gt 0 -and -not $Quiet) {
        $warnings | ForEach-Object { Write-Warning ("[preflight-smb] {0}" -f $_) }
    }
    if ($failures.Count -gt 0) {
        return [pscustomobject]@{
            Ok       = $false
            Failures = @($failures.ToArray())
            Warnings = @($warnings.ToArray())
        }
    }
    return [pscustomobject]@{
        Ok       = $true
        Failures = @()
        Warnings = @($warnings.ToArray())
    }
}
