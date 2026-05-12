#Requires -RunAsAdministrator
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'mast-log.ps1')

# ---------------------------
# Logging
# ---------------------------
function Start-ProvisionLog {
  [CmdletBinding()]
  param(
    [string]${Component} = "provision",
    [string]${LogRoot} = ''
  )
  if (-not ${LogRoot}) { ${LogRoot} = Get-MastLogSessionDir }
  ${null} = New-Item -ItemType Directory -Path ${LogRoot} -Force -ErrorAction SilentlyContinue
  ${LogFile} = Join-Path ${LogRoot} ("{0}_{1:yyyyMMdd_HHmmss}.log" -f ${Component}, (Get-Date))
  Start-Transcript -Path ${LogFile} -Append | Out-Null
  return ${LogFile}
}

function Stop-ProvisionLog {
  [CmdletBinding()] param()
  try { Stop-Transcript | Out-Null } catch {}
}

# ---------------------------
# Environment / PATH
# ---------------------------
function Add-ToSystemPath {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]${Dir})
  ${envKey}  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  ${pathVal} = (Get-ItemProperty -Path ${envKey} -Name PATH -ErrorAction SilentlyContinue).Path
  if (-not ${pathVal}) { ${pathVal} = '' }
  if (${pathVal} -notmatch [Regex]::Escape(${Dir})) {
    ${newPath} = (${pathVal}.TrimEnd(';') + ';' + ${Dir}).Trim(';')
    Set-ItemProperty -Path ${envKey} -Name PATH -Value ${newPath}
    Broadcast-Environment
    Write-Verbose "PATH += ${Dir}"
  } else {
    Write-Verbose "PATH already contains ${Dir}"
  }
}

function Broadcast-Environment {
  $sig = @"
using System;
using System.Runtime.InteropServices;
public class NativeMethods {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
  public static extern IntPtr SendMessageTimeout(IntPtr hWnd, int Msg, IntPtr wParam, string lParam, int fuFlags, int uTimeout, out IntPtr lpdwResult);
}
"@
  Add-Type -TypeDefinition $sig -ErrorAction SilentlyContinue | Out-Null
  [void][NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]0, 'Environment', 2, 5000, [ref]([IntPtr]::Zero))
}

# ---------------------------
# Files / Directories / Hash
# ---------------------------
function Confirm-Dir { param([Parameter(Mandatory)][string]${Path}) if (-not (Test-Path ${Path})) { New-Item -ItemType Directory -Path ${Path} -Force | Out-Null } }

function Copy-Safe {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]${Source},
    [Parameter(Mandatory)][string]${Destination},
    [switch]${Recurse}
  )
  Confirm-Dir (Split-Path -Parent ${Destination})
  if (Test-Path ${Destination}) { Remove-Item -Force -Recurse ${Destination} -ErrorAction SilentlyContinue }
  if (${Recurse}) {
    robocopy "${Source}" "${Destination}" /E /NFL /NDL /NJH /NJS /NP | Out-Null
  } else {
    Copy-Item -Force -Path ${Source} -Destination ${Destination}
  }
}

function Get-FileSha256 { param([Parameter(Mandatory)][string]${Path}) return (Get-FileHash -Algorithm SHA256 -Path ${Path}).Hash }

# ---------------------------
# Executables / Installers
# ---------------------------
function Invoke-Exe {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]${FilePath},
    [string]${Arguments} = '',
    [int[]]${OkCodes} = @(0),
    [string]${Tag} = 'exe'
  )
  Write-Verbose "${Tag}: ${FilePath} ${Arguments}"
  ${p} = Start-Process -FilePath ${FilePath} -ArgumentList ${Arguments} -PassThru -Wait -WindowStyle Hidden
  try { ${p}.Refresh() } catch {}
  if ($null -eq ${p}.ExitCode) {
    throw "${Tag}: missing ExitCode after Wait (treat as failure)"
  }
  if (${OkCodes} -notcontains ${p}.ExitCode) { throw "${Tag} exit code $(${p}.ExitCode)" }
}

function Invoke-ExeSilent {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]${FilePath},
    [string[]]${ArgsList} = @('/S','/silent','/verysilent /norestart','/quiet /norestart'),
    [string]${Tag} = 'install'
  )
  foreach (${a} in ${ArgsList}) {
    try { Invoke-Exe -FilePath ${FilePath} -Arguments ${a} -Tag ${Tag}; return $true }
    catch { Write-Warning "${Tag}: ${FilePath} ${a} -> $($_.Exception.Message)" }
  }
  return $false
}

# ---------------------------
# Archives
# ---------------------------
function Expand-AnyArchive {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]${ArchivePath},
    [Parameter(Mandatory)][string]${Destination}
  )
  Confirm-Dir ${Destination}
  ${ext} = [IO.Path]::GetExtension(${ArchivePath}).ToLowerInvariant()
  switch (${ext}) {
    '.zip' { Expand-Archive -Path ${ArchivePath} -DestinationPath ${Destination} -Force; break }
    '.cab' { & expand.exe -F:* "`"${ArchivePath}`"" "`"${Destination}`""; if ($LASTEXITCODE -ne 0) { throw "expand.exe failed ${LASTEXITCODE}" }; break }
    default {
      # handle .tgz/.tar.gz/.tar: use tar.exe if present
      ${Tar} = Join-Path ${env:SystemRoot} 'System32\tar.exe'
      if (Test-Path ${Tar}) {
        & ${Tar} -x -f "`"${ArchivePath}`"" -C "`"${Destination}`""
        if ($LASTEXITCODE -ne 0) { throw "tar failed ${LASTEXITCODE}" }
      } else {
        throw "No handler for ${ext}; tar.exe not found"
      }
    }
  }
}

# ---------------------------
# Services
# ---------------------------
function Restart-ServiceLike {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]${Pattern})
  ${svc} = Get-Service | Where-Object { $_.Name -match ${Pattern} -or $_.DisplayName -match ${Pattern} } | Select-Object -First 1
  if (${svc}) {
    Restart-Service -InputObject ${svc} -Force -ErrorAction SilentlyContinue
    Write-Verbose "Restarted service: $(${svc}.Name)"
  } else {
    Write-Verbose "No service matched pattern: ${Pattern}"
  }
}

# ---------------------------
# CSV (simple, header optional)
# ---------------------------
function Read-SimpleCsv2 {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]${Path})
  if (-not (Test-Path ${Path})) { return @() }
  ${content} = Get-Content -Path ${Path} -ErrorAction SilentlyContinue
  if (-not ${content} -or ${content}.Count -eq 0) { return @() }
  ${first} = ${content}[0]
  ${hasHeader} = (${first} -match ',') -and (-not (${first} -match '\.lic,')) # crude heuristic
  if (${hasHeader}) {
    try { return (Import-Csv -Path ${Path}) } catch {}
  }
  # manual
  ${rows} = @()
  foreach (${line} in $(if (${hasHeader}) { ${content} | Select-Object -Skip 1 } else { ${content} })) {
    if (-not ${line}) { continue }
    ${parts} = ${line}.Split(',',2)
    if (${parts}.Count -ge 2) { ${rows} += [PSCustomObject]@{ column1 = ${parts}[0].Trim(); column2 = ${parts}[1].Trim() } }
  }
  return ${rows}
}

function Write-SimpleCsv2 {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]${Path},
    [Parameter(Mandatory)][object[]]${Rows},
    [string[]]${Header} = @('column1','column2')
  )
  ${tmp} = "${Path}.tmp"
  (${Header} -join ',') | Out-File -FilePath ${tmp} -Encoding UTF8
  foreach (${r} in ${Rows}) {
    ${vals} = @()
    foreach (${h} in ${Header}) { ${vals} += (${r}.${h}) }
    (${vals} -join ',') | Out-File -FilePath ${tmp} -Append -Encoding UTF8
  }
  Move-Item -Force -Path ${tmp} -Destination ${Path}
}

# ---------------------------
# System info / misc
# ---------------------------
function Get-WorkingDir { if (${PSCommandPath}) { return (Split-Path -Parent ${PSCommandPath}) } else { return (Get-Location).Path } }

function Test-IsAdmin {
  try {
    ${id} = [Security.Principal.WindowsIdentity]::GetCurrent()
    ${p}  = New-Object Security.Principal.WindowsPrincipal(${id})
    return ${p}.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
  } catch { return $false }
}

# ---------------------------
# Windows Features (optional)
# ---------------------------
function Enable-NetFx3 {
  [CmdletBinding()]
  param([string]${FoDSource})
  try {
    Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart -ErrorAction Stop | Out-Null
    return $true
  } catch {
    Write-Warning "NetFx3 online enable failed: $($_.Exception.Message)"
  }
  ${candidates} = @()
  if (${FoDSource}) { ${candidates} += ${FoDSource} }
  ${candidates} += @("A:\sources\sxs","D:\sources\sxs","E:\sources\sxs","F:\sources\sxs","G:\sources\sxs")
  foreach (${src} in ${candidates} | Get-Unique) {
    if (Test-Path ${src}) {
      & dism.exe /Online /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:${src} | Out-Null
      if ($LASTEXITCODE -eq 0) { return $true }
    }
  }
  return $false
}
Export-ModuleMember -Function @(
  'Start-ProvisionLog', 'Stop-ProvisionLog', 'Add-ToSystemPath', 'Confirm-Dir', 'Copy-Safe',
  'Get-FileSha256', 'Invoke-Exe', 'Invoke-ExeSilent', 'Expand-AnyArchive', 'Restart-ServiceLike',
  'Read-SimpleCsv2', 'Write-SimpleCsv2', 'Get-WorkingDir', 'Test-IsAdmin', 'Enable-NetFx3',
  'Get-MastLogSessionDir', 'Get-MastSmokeDir', 'Get-MastVerifyDir'
)
