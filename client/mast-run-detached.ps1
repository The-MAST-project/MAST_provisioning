<#
Standalone detached-execute runner for the autonomous provisioning driver.

Runs execute-mast-provisioning.ps1 DETACHED from the orchestrator's transport
session, so a WinRM/SSH drop mid-execute no longer kills the run. All the
detachment + status-marker logic lives here (one testable unit-side artifact);
the driver just writes the inputs, invokes this with -Register, and polls the
result marker.

Two modes:
  -Register : register + start a one-shot scheduled task (interactive 'mast',
              elevated) that re-invokes this script with -Run, then return
              immediately. The task is triggerless -- it only runs when Started
              -- so it never re-fires on its own at a later logon.
  -Run      : (invoked by the task, in the interactive session) read the config,
              decrypt the SMB password from the DPAPI-LocalMachine blob, run
              execute-mast-provisioning.ps1, and write execute-result.json
              ('running' at start, then 'done' + exit_code).

Inputs the driver writes to <SystemDrive>\MAST\status\ before -Register:
  detached-run.json  { run_id, staging_path, prov_server, smb_user, held_by }
  smb-cred.dpapi     LocalMachine-DPAPI blob of the SMB password (machine-bound)

Output the driver polls:
  execute-result.json { run_id, status: running|done, exit_code, started_utc, ended_utc }

ASCII-only; Windows PowerShell 5.1 safe.
#>
[CmdletBinding()]
param(
    [switch]${Register},
    [switch]${Run}
)

${ErrorActionPreference} = 'Continue'

${statusDir}  = Join-Path ${env:SystemDrive} 'MAST\status'
${cfgPath}    = Join-Path ${statusDir} 'detached-run.json'
${blobPath}   = Join-Path ${statusDir} 'smb-cred.dpapi'
${resultPath} = Join-Path ${statusDir} 'execute-result.json'
${taskName}   = 'MAST-Execute-Detached'
${selfPath}   = ${MyInvocation}.MyCommand.Path

function Write-ResultAtomic {
    param([hashtable]${Obj})
    ${null} = New-Item -ItemType Directory -Force -Path ${statusDir} -ErrorAction SilentlyContinue
    ${tmp} = "${resultPath}.tmp"
    ${json} = (${Obj} | ConvertTo-Json -Compress)
    [System.IO.File]::WriteAllText(${tmp}, ${json}, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Force ${tmp} ${resultPath}
}

if (${Register}) {
    Remove-Item ${resultPath} -Force -ErrorAction SilentlyContinue
    schtasks /delete /tn ${taskName} /f *> $null
    ${arg} = ('-NoProfile -ExecutionPolicy Bypass -File "' + ${selfPath} + '" -Run')
    ${act}  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ${arg}
    ${prin} = New-ScheduledTaskPrincipal -UserId 'mast' -LogonType Interactive -RunLevel Highest
    # No trigger: the task only runs when explicitly Started, so it cannot
    # re-fire at a future logon and re-provision the unit.
    Register-ScheduledTask -TaskName ${taskName} -Action ${act} -Principal ${prin} -Force | Out-Null
    Start-ScheduledTask -TaskName ${taskName}
    Write-Output 'DETACHED_REGISTERED'
    return
}

if (${Run}) {
    ${cfg} = Get-Content ${cfgPath} -Raw | ConvertFrom-Json
    Write-ResultAtomic -Obj @{
        run_id      = ${cfg}.run_id
        status      = 'running'
        pid         = $PID
        started_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    # Decrypt the SMB password from the machine-bound DPAPI blob (never plaintext
    # on disk). LocalMachine scope: any session on this machine can decrypt.
    Add-Type -AssemblyName System.Security
    ${smbPass} = ''
    try {
        ${enc} = [System.IO.File]::ReadAllBytes(${blobPath})
        ${dec} = [System.Security.Cryptography.ProtectedData]::Unprotect(
            ${enc}, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        ${smbPass} = [System.Text.Encoding]::UTF8.GetString(${dec})
    } catch {
        # Leave smbPass empty; execute logs the Z: mapping failure and continues.
    }

    ${exe} = Join-Path ${cfg}.staging_path 'execute-mast-provisioning.ps1'
    & ${exe} `
        -StagingPath ${cfg}.staging_path `
        -ProvServer  ${cfg}.prov_server `
        -SmbUser     ${cfg}.smb_user `
        -SmbPass     ${smbPass} `
        -RunId       ${cfg}.run_id `
        -HeldBy      ${cfg}.held_by `
        -AllowReboot
    ${rc} = $LASTEXITCODE
    if ($null -eq ${rc}) { ${rc} = 0 }

    Write-ResultAtomic -Obj @{
        run_id    = ${cfg}.run_id
        status    = 'done'
        exit_code = [int]${rc}
        ended_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    return
}

Write-Output 'usage: mast-run-detached.ps1 -Register | -Run'
