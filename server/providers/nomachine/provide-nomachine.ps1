<#
.SYNOPSIS
  Provision NoMachine: install Enterprise Client & Desktop, allocate and install a license.

.DESCRIPTION
  - Expects these under ${AssetsRoot}\nomachine\assets:
      nomachine-enterprise-client_9.0.188_11_x64.exe
      nomachine-enterprise-desktop_9.0.188_11_x64.exe
      nomachine.lic .. server-10.lic
  - Installs both packages silently (multiple flag attempts).
  - Allocates a license based on ${env:COMPUTERNAME} if not already allocated.
  - Installs the license file into the NoMachine licenses directory.
  - Tries to restart NoMachine service so license is picked up.
  - Logs to %ProgramData%\MAST\logs.

.PARAMETER AssetsRoot
  Root containing 'nomachine\assets'. Default: ${PSScriptRoot}.

.PARAMETER InstallDir
  Base folder where NoMachine typically installs. Only used for detection/help; installer sets its own path.

.PARAMETER Help
  Show usage.

.NOTES
  Run as admin. Suitable for WCD ProvisioningCommands -> DeviceContext.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]${AssetsRoot} = ${PSScriptRoot},
  [string]${InstallDir} = 'C:\Program Files\NoMachine',
  [switch]${Help}
)

try {
  ${provLocal} = Join-Path ${PSScriptRoot} 'provisioning.psm1'
  ${provGlobal} = 'C:\ProgramData\MAST\provisioning.psm1'
  Import-Module (Test-Path ${provLocal} ? ${provLocal} : ${provGlobal}) -Force -DisableNameChecking
} catch { Write-Warning "provisioning.psm1 import failed: $($_.Exception.Message)" }

function Show-Help {
@"
provide-nomachine.ps1

USAGE:
  .\provide-nomachine.ps1 [-AssetsRoot <path>] [-InstallDir <dir>] [-Verbose] [-Help]

FILES (under ${AssetsRoot}):
  nomachine-enterprise-client_9.0.188_11_x64.exe
  nomachine-enterprise-desktop_9.0.188_11_x64.exe
  nomachine.lic
"@ | Write-Host
}
if (${Help}) { Show-Help; return }

# --- Logging ---
${LogRoot} = Join-Path ${env:ProgramData} 'MAST\logs'
${null} = New-Item -ItemType Directory -Path ${LogRoot} -Force -ErrorAction SilentlyContinue
${LogFile} = Join-Path ${LogRoot} ("provide-nomachine_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path ${LogFile} -Append | Out-Null
Write-Verbose "Log: ${LogFile}"

# --- Paths & Inputs ---
${assets}     = ${AssetsRoot}
${clientExe}  = Join-Path ${assets} 'nomachine-enterprise-client_9.0.188_11_x64.exe'
${serverExe}  = Join-Path ${assets} 'nomachine-enterprise-desktop_9.0.188_11_x64.exe'
${licFile} = Join-Path ${PSScriptRoot} "nomachine.lic"

if (-not (Test-Path ${assets}))    { Stop-Transcript | Out-Null; throw "Assets not found: ${assets}" }
if (-not (Test-Path ${clientExe})) { Stop-Transcript | Out-Null; throw "Missing Enterprise Client: ${clientExe}" }
if (-not (Test-Path ${serverExe})) { Stop-Transcript | Out-Null; throw "Missing Enterprise Desktop: ${serverExe}" }

# --- Helpers ---
function Try-InstallExe {
  param(
    [Parameter(Mandatory)][string]${FilePath},
    [string[]]${ArgsList} = @('/verysilent /usbinstall="0" /printerinstall="0"'),
    [string]${Tag} = 'install'
  )
  foreach (${a} in ${ArgsList}) {
    try {
      Write-Host "${Tag}: ${FilePath} ${a}"
      ${p} = Start-Process -FilePath ${FilePath} -ArgumentList ${a} -PassThru -Wait -WindowStyle Hidden
      if (${p}.ExitCode -eq 0) { return $true }
      Write-Warning "${Tag}: exit code $(${p}.ExitCode) with args '${a}'"
    } catch {
      Write-Warning "${Tag}: ${FilePath} '${a}' failed: $($_.Exception.Message)"
    }
  }
  return $false
}

function Install-License {
  param([Parameter(Mandatory)][string]${SourceLicPath})
  ${targetDir} = Join-Path ${InstallDir} 'etc'
  ${targetPath} = Join-Path ${targetDir} "server.lic"
  Copy-Item -Path ${licFile} -Destination ${targetPath} -Force
  Write-Host "License installed to ${targetPath}"
  # Try to restart a NoMachine service if present so new license is read
  try {
    ${svc} = Get-Service | Where-Object { $_.Name -match 'NoMachine|nx' -or $_.DisplayName -match 'NoMachine' } | Select-Object -First 1
    if (${svc}) {
      Restart-Service -InputObject ${svc} -Force -ErrorAction SilentlyContinue
      Write-Host "Restarted service: ${svc.Name}"
    } else {
      Write-Verbose "No NoMachine service detected to restart."
    }
  } catch {
    Write-Warning "Service restart failed: $($_.Exception.Message)"
  }
}

# --- Install Client & Server (Desktop) ---
if (-not (Try-InstallExe -FilePath ${clientExe} -Tag 'NoMachine Client')) {
  Write-Warning "NoMachine Enterprise Client install may have failed. Check logs."
}
if (-not (Try-InstallExe -FilePath ${serverExe} -Tag 'NoMachine Enterprise Desktop')) {
  Write-Warning "NoMachine Enterprise Desktop (server) install may have failed. Check logs."
}
Install-License -SourceLicPath ${licFile}

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
