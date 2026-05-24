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

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-openssh-server.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# Match mastw: sshd is the canonical inbound shell into the unit (used for
# the compare-mastw diff capture, among other things). Install via the
# in-box Windows optional capability so we do not have to ship a binary.
try {
    Write-SshLog "Checking OpenSSH.Server capability state..."
    ${cap} = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop
    Write-SshLog ("OpenSSH.Server state: {0}" -f ${cap}.State)
    if (${cap}.State -ne 'Installed') {
        Write-SshLog "Adding OpenSSH.Server capability..."
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop | Out-Null
        Write-SshLog "OpenSSH.Server capability installed."
    } else {
        Write-SshLog "OpenSSH.Server already installed; skipping Add-WindowsCapability."
    }

    Write-SshLog "Setting sshd service to Automatic and starting..."
    Set-Service -Name 'sshd' -StartupType Automatic -ErrorAction Stop
    Start-Service -Name 'sshd' -ErrorAction Stop
    Write-SshLog "sshd service running."

    # ssh-agent is helpful but not strictly required; align it too if present.
    ${agentSvc} = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
    if ($null -ne ${agentSvc}) {
        Set-Service -Name 'ssh-agent' -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
        Write-SshLog "ssh-agent service started."
    }

    ${fwRuleName} = 'MAST OpenSSH Server (TCP 22)'
    if (-not (Get-NetFirewallRule -DisplayName ${fwRuleName} -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName ${fwRuleName} -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort 22 -Profile Any -ErrorAction Stop | Out-Null
        Write-SshLog ("Firewall rule created: {0}" -f ${fwRuleName})
    } else {
        Write-SshLog ("Firewall rule already exists: {0}" -f ${fwRuleName})
    }

    # sshd_config: Windows OpenSSH ships with PasswordAuthentication yes by
    # default, but mastw confirmed password auth as the entry point so we
    # assert it explicitly. Touch the file only if needed to keep this run
    # idempotent.
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
            Write-SshLog "sshd_config updated; sshd restarted."
        } else {
            Write-SshLog "sshd_config already permits password auth; no change."
        }
    } else {
        Write-SshLog ("WARNING: sshd_config not found at {0}; relying on defaults." -f ${cfgPath})
    }

    ${smokeDir} = Get-MastSmokeDir
    New-Item -ItemType Directory -Path ${smokeDir} -Force | Out-Null
    Set-Content -LiteralPath (Join-Path ${smokeDir} 'openssh-server-smoke.txt') -Encoding UTF8 -Value 'openssh_server_ok'

    Write-SshLog "OpenSSH server provisioning completed successfully."
    exit 0
}
catch {
    ${errorMsg} = ("OpenSSH server provisioning failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
