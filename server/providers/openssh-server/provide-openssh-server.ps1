param(
    [string]${MastUser} = "mast"
)

${ErrorActionPreference} = "Stop"
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}

${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "openssh-server-install.log"

function Write-SshLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value `
    ("[{0}] provide-openssh-server.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

<#
Post-bootstrap OpenSSH idempotency / drift check.

Bootstrap (client\bootstrap-winrm.ps1) owns the heavy work: installs the
OpenSSH.Server Windows capability, sets sshd + ssh-agent to Automatic,
starts them, opens firewall TCP 22, and asserts PasswordAuthentication yes
in sshd_config. That all has to happen in an interactive admin shell --
Add-WindowsCapability is rejected by DISM under the WinRM network logon
used by provisioning, even when the user is a full admin (see 2026-05-25
DECISIONS entry).

This provider runs at provision-time over WinRM and just asserts the
bootstrap configuration didn't drift:
  - sshd service is registered and Running with StartType=Automatic
  - inbound TCP 22 firewall rule exists
  - sshd_config still has PasswordAuthentication yes

If something is off, log a clear warning and start sshd (Start-Service IS
allowed under WinRM, only the capability install is not). Never try to
Add-WindowsCapability here -- it'll just fail with Access is denied and
mask the real problem.
#>

try {
    # 1. sshd service must exist (means bootstrap installed the capability).
    ${svc} = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
    if ($null -eq ${svc}) {
        # Bootstrap's in-box capability install needs Windows Update
        # reachability AND an interactive token; an offline-bootstrapped unit
        # (mast03) arrives here with no sshd and no way to add it via DISM
        # over WinRM (FoD kept failing 0x8024402c even as SYSTEM). The
        # bundled Win32-OpenSSH MSI has neither dependency: msiexec installs
        # sshd + ssh-agent + the firewall rule fine under the WinRM logon.
        ${msi} = Join-Path ${PSScriptRoot} 'OpenSSH-Win64-v10.0.0.0.msi'
        if (-not (Test-Path -LiteralPath ${msi})) { ${msi} = Join-Path ${PSScriptRoot} 'assets\OpenSSH-Win64-v10.0.0.0.msi' }
        if (-not (Test-Path -LiteralPath ${msi})) {
            throw "sshd is not registered and the bundled OpenSSH MSI is missing from the payload. Re-run bootstrap online, or restage the payload."
        }
        Write-SshLog ("sshd not registered; installing bundled Win32-OpenSSH: {0}" -f ${msi})
        ${mp} = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', ('"{0}"' -f ${msi}), '/qn', '/norestart') -PassThru -Wait -WindowStyle Hidden
        try { ${mp}.Refresh() } catch {}
        if ($null -eq ${mp}.ExitCode -or ((${mp}.ExitCode -ne 0) -and (${mp}.ExitCode -ne 3010))) {
            throw ("OpenSSH MSI install failed (msiexec exit {0})." -f ${mp}.ExitCode)
        }
        ${svc} = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
        if ($null -eq ${svc}) { throw 'OpenSSH MSI reported success but sshd is still not registered.' }
        Write-SshLog 'Win32-OpenSSH installed (sshd registered).'
    }
    Write-SshLog ("sshd: Status={0} StartType={1}" -f ${svc}.Status, ${svc}.StartType)

    # 2. StartType should be Automatic; correct it if not.
    if (${svc}.StartType -ne 'Automatic') {
        Write-SshLog ("Setting sshd StartType Automatic (was {0})." -f ${svc}.StartType)
        Set-Service -Name 'sshd' -StartupType Automatic -ErrorAction Stop
    }

    # 3. Status should be Running; start it if not.
    if (${svc}.Status -ne 'Running') {
        Write-SshLog "sshd not running; starting..."
        Start-Service -Name 'sshd' -ErrorAction Stop
        # Refresh and brief settle so the verify step sees Running.
        Start-Sleep -Seconds 2
        ${svc} = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
        Write-SshLog ("sshd post-start: Status={0}" -f ${svc}.Status)
    }

    # 4. Best-effort: ssh-agent service alignment (mirrors bootstrap behavior).
    ${agentSvc} = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
    if ($null -ne ${agentSvc}) {
        if (${agentSvc}.StartType -ne 'Automatic') {
            Set-Service -Name 'ssh-agent' -StartupType Automatic -ErrorAction SilentlyContinue
        }
        if (${agentSvc}.Status -ne 'Running') {
            Start-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
        }
    }

    # 5. Firewall rule. Cheap to re-create idempotently.
    ${fwRuleName} = 'MAST OpenSSH Server (TCP 22)'
    if (-not (Get-NetFirewallRule -DisplayName ${fwRuleName} -ErrorAction SilentlyContinue)) {
        Write-SshLog ("Firewall rule '{0}' missing; creating." -f ${fwRuleName})
        New-NetFirewallRule -DisplayName ${fwRuleName} -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort 22 -Profile Any -ErrorAction Stop | Out-Null
    }

    # 6. sshd_config drift check. The bootstrap script wrote
    # PasswordAuthentication yes; if something else flipped it, fix it.
    ${cfgPath} = 'C:\ProgramData\ssh\sshd_config'
    if (Test-Path -LiteralPath ${cfgPath}) {
        ${cfg} = Get-Content -LiteralPath ${cfgPath} -Raw -Encoding UTF8
        ${newCfg} = ${cfg}
        if (${newCfg} -match '(?m)^\s*PasswordAuthentication\s+no\b') {
            ${newCfg} = [regex]::Replace(${newCfg}, '(?m)^\s*PasswordAuthentication\s+no\b', 'PasswordAuthentication yes')
            Write-SshLog "Flipped PasswordAuthentication no -> yes in sshd_config."
        }
        if (${newCfg} -notmatch '(?m)^\s*PasswordAuthentication\s+yes\b') {
            ${newCfg} = ${newCfg}.TrimEnd() + "`r`nPasswordAuthentication yes`r`n"
            Write-SshLog "Appended PasswordAuthentication yes to sshd_config."
        }
        if (${newCfg} -ne ${cfg}) {
            Set-Content -LiteralPath ${cfgPath} -Value ${newCfg} -Encoding UTF8
            Restart-Service -Name 'sshd' -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-SshLog ("WARN: sshd_config not found at {0}." -f ${cfgPath})
    }

    # 7. Drop the smoke marker so the verify step's content matches the
    # existing module.json verify (which expects sshd Running anyway).
    ${smokeDir} = Get-MastSmokeDir
    New-Item -ItemType Directory -Path ${smokeDir} -Force | Out-Null
    Set-Content -LiteralPath (Join-Path ${smokeDir} 'openssh-server-smoke.txt') -Encoding UTF8 -Value 'openssh_server_ok'

    Write-SshLog "OpenSSH post-bootstrap idempotency check completed successfully."
    exit 0
}
catch {
    ${errorMsg} = ("OpenSSH provisioning failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
