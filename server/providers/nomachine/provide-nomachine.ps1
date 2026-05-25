<#
.SYNOPSIS
  Provision NoMachine: install Enterprise Desktop (server-side) and apply license if provided.

.DESCRIPTION
  - Expects these under ${AssetsRoot}\nomachine\assets:
      nomachine-enterprise-desktop_9.0.188_11_x64.exe
      nomachine.lic .. server-10.lic
  - Enterprise Desktop is the server-capable single-workstation product; it accepts
    incoming NoMachine sessions. The Client is intentionally NOT installed.
  - Installs silently (multiple flag attempts).
  - Allocates a license based on ${env:COMPUTERNAME} if not already allocated.
  - Installs the license file into the NoMachine licenses directory.
  - Tries to restart NoMachine service so license is picked up.
  - Logs under <SystemDrive>\MAST\logs\sessions\<timestamp>.

.PARAMETER AssetsRoot
  Root containing 'nomachine\assets'. Default: ${PSScriptRoot}.

.PARAMETER InstallDir
  Base folder where NoMachine typically installs. Only used for detection/help; installer sets its own path.

.PARAMETER RequireLicense
  Fail if no nomachine.lic is found under AssetsRoot (or script root fallback).

.PARAMETER Help
  Show usage.

.NOTES
  Run as admin. Suitable for WCD ProvisioningCommands -> DeviceContext.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]${AssetsRoot} = ${PSScriptRoot},
  [string]${InstallDir} = 'C:\Program Files\NoMachine',
  [switch]${RequireLicense},
  [switch]${Help}
)

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
if (-not (Test-Path ${mastLogDot})) { throw "mast-log.ps1 not found (expected in staging or server\lib)." }
. ${mastLogDot}

try {
  ${provLocal} = Join-Path ${PSScriptRoot} 'provisioning.psm1'
  ${provGlobal} = 'C:\ProgramData\MAST\provisioning.psm1'
  if (Test-Path ${provLocal}) {
    Import-Module ${provLocal} -Force -DisableNameChecking
  } else {
    Import-Module ${provGlobal} -Force -DisableNameChecking
  }
} catch { Write-Warning "provisioning.psm1 import failed: $($_.Exception.Message)" }

function Show-Help {
@"
provide-nomachine.ps1

USAGE:
  .\provide-nomachine.ps1 [-AssetsRoot <path>] [-InstallDir <dir>] [-RequireLicense] [-Verbose] [-Help]

FILES (under ${AssetsRoot}, preferably nomachine\assets):
  nomachine-enterprise-desktop_9.0.188_11_x64.exe
  nomachine.lic (optional unless -RequireLicense)
"@ | Write-Host
}
if (${Help}) { Show-Help; return }

# --- Logging ---
${LogRoot} = Get-MastLogSessionDir
${null} = New-Item -ItemType Directory -Path ${LogRoot} -Force -ErrorAction SilentlyContinue
${LogFile} = Join-Path ${LogRoot} ("provide-nomachine_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path ${LogFile} -Append | Out-Null
Write-Verbose "Log: ${LogFile}"

# --- Paths & Inputs ---
${assets} = ${AssetsRoot}
${nmAssets} = Join-Path ${assets} 'nomachine\assets'

${serverExe} = $null
foreach (${c} in @(
    (Join-Path ${nmAssets} 'nomachine-enterprise-desktop_9.0.188_11_x64.exe'),
    (Join-Path ${assets} 'nomachine-enterprise-desktop_9.0.188_11_x64.exe')
  )) {
  if (Test-Path -LiteralPath ${c}) { ${serverExe} = ${c}; break }
}

${licFile} = $null
foreach (${c} in @(
    (Join-Path ${nmAssets} 'nomachine.lic'),
    (Join-Path ${assets} 'nomachine.lic'),
    (Join-Path ${PSScriptRoot} 'nomachine.lic')
  )) {
  if (Test-Path -LiteralPath ${c}) { ${licFile} = ${c}; break }
}

if (-not (Test-Path ${assets})) { Stop-Transcript | Out-Null; throw "Assets not found: ${assets}" }
if (-not ${serverExe}) {
  Stop-Transcript | Out-Null
  throw "Missing Enterprise Desktop under ${nmAssets} or ${assets}"
}
if (${RequireLicense} -and -not ${licFile}) {
  Stop-Transcript | Out-Null
  throw "NoMachine license required (-RequireLicense) but not found under ${nmAssets}, ${assets}, or ${PSScriptRoot}."
}

# --- Helpers ---
function Stop-ProcessTree {
  param([Parameter(Mandatory)][int]${RootPid})
  try {
    ${all} = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    if ($null -eq ${all}) { return }
    ${byParent} = @{}
    foreach (${p} in ${all}) {
      ${ppid} = [int]${p}.ParentProcessId
      if (-not ${byParent}.ContainsKey(${ppid})) { ${byParent}[${ppid}] = @() }
      ${byParent}[${ppid}] += [int]${p}.ProcessId
    }
    ${order} = New-Object System.Collections.Generic.List[int]
    ${queue} = New-Object System.Collections.Generic.Queue[int]
    ${queue}.Enqueue(${RootPid})
    while (${queue}.Count -gt 0) {
      ${cur} = ${queue}.Dequeue()
      ${order}.Add(${cur})
      if (${byParent}.ContainsKey(${cur})) {
        foreach (${c} in ${byParent}[${cur}]) { ${queue}.Enqueue(${c}) }
      }
    }
    # Kill leaves first
    [array]::Reverse(${order})
    foreach (${pidToKill} in ${order}) {
      try { Stop-Process -Id ${pidToKill} -Force -ErrorAction SilentlyContinue } catch {}
    }
  } catch {
    Write-Warning "Stop-ProcessTree: $($_.Exception.Message)"
  }
}

function Test-NoMachineInstalled {
  ${nxExe} = Join-Path ${InstallDir} 'bin\nxserver.exe'
  if (-not (Test-Path -LiteralPath ${nxExe})) { return $false }
  ${svc} = Get-Service -Name 'nxservice' -ErrorAction SilentlyContinue
  if ($null -eq ${svc}) { return $false }
  return (${svc}.Status -eq 'Running')
}

function Try-InstallExe {
  param(
    [Parameter(Mandatory)][string]${FilePath},
    [string[]]${ArgsList} = @('/verysilent /usbinstall="0" /printerinstall="0"'),
    [string]${Tag} = 'install',
    [int]${TimeoutSec} = 600,
    [int]${PostInstallGraceSec} = 20,
    [scriptblock]${SuccessProbe} = $null
  )
  foreach (${a} in ${ArgsList}) {
    try {
      Write-Host "${Tag}: ${FilePath} ${a}"
      ${p} = Start-Process -FilePath ${FilePath} -ArgumentList ${a} -PassThru -WindowStyle Hidden
      ${deadline} = (Get-Date).AddSeconds(${TimeoutSec})
      ${probeStableSince} = $null
      while ($true) {
        if (${p}.HasExited) { break }
        if (${SuccessProbe}) {
          ${ok} = $false
          try { ${ok} = [bool](& ${SuccessProbe}) } catch { ${ok} = $false }
          if (${ok}) {
            if ($null -eq ${probeStableSince}) {
              ${probeStableSince} = Get-Date
              Write-Host "${Tag}: success probe satisfied; allowing ${PostInstallGraceSec}s for installer to exit."
            } elseif (((Get-Date) - ${probeStableSince}).TotalSeconds -ge ${PostInstallGraceSec}) {
              Write-Warning "${Tag}: installer (PID $(${p}.Id)) still running after success; terminating tree."
              Stop-ProcessTree -RootPid ${p}.Id
              Start-Sleep -Seconds 2
              return $true
            }
          } else {
            ${probeStableSince} = $null
          }
        }
        if ((Get-Date) -gt ${deadline}) {
          Write-Warning "${Tag}: timeout after ${TimeoutSec}s waiting on PID $(${p}.Id); terminating tree."
          Stop-ProcessTree -RootPid ${p}.Id
          Start-Sleep -Seconds 2
          if (${SuccessProbe}) {
            try { if (& ${SuccessProbe}) { return $true } } catch {}
          }
          break
        }
        Start-Sleep -Seconds 2
      }
      try { ${p}.Refresh() } catch {}
      ${exit} = $null
      try { ${exit} = ${p}.ExitCode } catch {}
      if ($null -eq ${exit} -or ${exit} -eq 0) { return $true }
      Write-Warning "${Tag}: exit code ${exit} with args '${a}'"
    } catch {
      Write-Warning "${Tag}: ${FilePath} '${a}' failed: $($_.Exception.Message)"
    }
  }
  return $false
}

function Install-License {
  param([Parameter(Mandatory)][string]${SourceLicPath})
  if (-not (Test-Path -LiteralPath ${SourceLicPath})) {
    Write-Warning "Install-License: missing source file (${SourceLicPath})."
    return
  }
  ${targetDir} = Join-Path ${InstallDir} 'etc'
  if (-not (Test-Path -LiteralPath ${targetDir})) {
    New-Item -ItemType Directory -Path ${targetDir} -Force | Out-Null
  }
  ${targetPath} = Join-Path ${targetDir} "server.lic"
  Copy-Item -LiteralPath ${SourceLicPath} -Destination ${targetPath} -Force
  Write-Host "License installed to ${targetPath}"
  try {
    ${svc} = Get-Service -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match 'NoMachine|nx' -or $_.DisplayName -match 'NoMachine' } |
      Select-Object -First 1
    if ($null -ne ${svc}) {
      ${svcName} = ${svc}.Name
      Restart-Service -InputObject ${svc} -Force -ErrorAction SilentlyContinue
      Write-Host "Restarted service: ${svcName}"
    } else {
      Write-Verbose "No NoMachine service detected to restart."
    }
  } catch {
    Write-Warning "Service restart failed: $($_.Exception.Message)"
  }
}

# --- Idempotency: skip install if already present and service running ---
if (Test-NoMachineInstalled) {
  Write-Host "NoMachine already installed and nxservice running; skipping installer execution."
} else {
  # --- Install Server (Enterprise Desktop) ---
  # The Inno Setup wrapper for NoMachine Enterprise Desktop has been observed to
  # not exit cleanly under /verysilent even after the service is up and binaries
  # are in place. Use a success probe + grace + forced terminate to avoid hangs.
  ${desktopProbe} = { Test-NoMachineInstalled }

  if (-not (Try-InstallExe -FilePath ${serverExe} -Tag 'NoMachine Enterprise Desktop' -TimeoutSec 600 -SuccessProbe ${desktopProbe})) {
    Write-Warning "NoMachine Enterprise Desktop (server) install may have failed. Check logs."
  }
}
if (${licFile}) {
  Install-License -SourceLicPath ${licFile}
} else {
  Write-Warning "NoMachine license file not found; skipping license install (use -RequireLicense to fail if missing)."
}

# --- Quick verification ---
try {
  ${nxInstallDir} = (Get-ChildItem -Path 'C:\Program Files*' -Directory -Filter 'NoMachine' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
  if (${nxInstallDir}) {
    ${nxBin} = Join-Path ${nxInstallDir} 'bin'
    if (Test-Path ${nxBin}) {
      Write-Host "NoMachine installed under: ${nxInstallDir}"
    }
  }
} catch { }

Write-Host "NoMachine provisioning finished. Log: ${LogFile}"
Stop-Transcript | Out-Null
exit 0
