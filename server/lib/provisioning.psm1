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
function Invoke-ExeAsSystem {
  # Run an .exe as NT AUTHORITY\SYSTEM via a one-shot scheduled task and
  # return its exit code. Use this for installers that need an unfiltered
  # admin token (kernel driver install, MSI bootstrap, DISM) -- under WinRM
  # the caller's NTLM token is filtered (BUILTIN\Administrators stripped
  # from the effective groups) even when IsAdmin reports True, so installs
  # that probe SeLoadDriverPrivilege or similar will silently no-op or
  # hang waiting for a UAC dialog that never appears.
  #
  # The first user of this pattern was provide-ascom.ps1 (Invoke-DismViaSystemTask)
  # for NetFx3 enablement. Extracted here 2026-05-26 so npcap and usbpcap
  # can share the same battle-tested implementation. ASCOM still has its
  # inline copy; cleanup pass is a follow-up.
  param(
    [Parameter(Mandatory)][string]${Executable},
    [string]${Arguments}             = '',
    [int]   ${TimeoutMinutes}        = 30,
    [string]${TaskNamePrefix}        = 'MAST-AsSystem'
  )
  ${taskName} = ${TaskNamePrefix} + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 12))
  if (-not (Test-Path -LiteralPath ${Executable})) {
    throw ("Invoke-ExeAsSystem: executable not found: {0}" -f ${Executable})
  }
  # WorkingDirectory: scheduled tasks default to %WINDIR%\System32, which
  # breaks installers that look for relative paths (asset .sys/.cat/.inf
  # alongside the installer, bundled DLLs, etc.). Default to the
  # installer's own parent directory so relative paths resolve.
  ${workDir} = [System.IO.Path]::GetDirectoryName(${Executable})

  # Capture stdout + stderr from the SYSTEM-side process. Without this we
  # are flying blind whenever an installer fails -- run #12 had usbpcap
  # exit with HRESULT 0x80070002 (ERROR_FILE_NOT_FOUND) and we had no idea
  # which file. Wrap the action in cmd.exe so we can redirect stdout/stderr
  # to disk; the helper reads the log files at the end and surfaces tails
  # back to the caller's host.
  ${stdoutLog} = Join-Path ${env:TEMP} ("${taskName}.out.log")
  ${stderrLog} = Join-Path ${env:TEMP} ("${taskName}.err.log")
  Remove-Item -LiteralPath ${stdoutLog}, ${stderrLog} -Force -ErrorAction SilentlyContinue
  # cmd.exe /c "<exe>" <args> 1> "<out>" 2> "<err>"
  # Quote the exe path; arguments are passed as-is (caller's responsibility
  # to quote any internal spaces). cmd's redirects bind to the inner exe.
  ${cmdArgs} = ('/c ""' + ${Executable} + '"')
  if (-not [string]::IsNullOrEmpty(${Arguments})) {
    ${cmdArgs} = ${cmdArgs} + ' ' + ${Arguments}
  }
  ${cmdArgs} = ${cmdArgs} + (' 1> "{0}" 2> "{1}""' -f ${stdoutLog}, ${stderrLog})
  ${action} = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ${cmdArgs} -WorkingDirectory ${workDir}
  ${principal} = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  ${settings}  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::FromMinutes(${TimeoutMinutes} + 5)) -MultipleInstances IgnoreNew
  try {
    Register-ScheduledTask -TaskName ${taskName} -Action ${action} -Principal ${principal} -Settings ${settings} -Force | Out-Null
  } catch {
    throw ("Invoke-ExeAsSystem: Register-ScheduledTask failed: {0}" -f $_.Exception.Message)
  }
  try {
    Start-ScheduledTask -TaskName ${taskName}
    ${deadline}      = (Get-Date).AddMinutes(${TimeoutMinutes})
    ${sw}            = [System.Diagnostics.Stopwatch]::StartNew()
    ${lastHeartbeat} = 0
    ${heartbeatSec}  = 30
    Write-Host ("[Invoke-ExeAsSystem] {0} started: {1} {2}" -f ${taskName}, ${Executable}, ${Arguments})
    while ((Get-Date) -lt ${deadline}) {
      ${st} = Get-ScheduledTask -TaskName ${taskName} -ErrorAction Stop
      if (${st}.State -ne 'Running') { break }
      # Heartbeat: every 30 seconds, log that we are still waiting. Critical
      # for observability of slow installs (NetFx3 DISM CDN download, npcap
      # driver install, etc.) -- without this we used to look at multi-minute
      # silence and have no idea whether the task was working or hung.
      ${elapsed} = ${sw}.Elapsed.TotalSeconds
      if ((${elapsed} - ${lastHeartbeat}) -ge ${heartbeatSec}) {
        Write-Host ("[Invoke-ExeAsSystem] {0} still running, elapsed={1:N0}s, state={2}" -f ${taskName}, ${elapsed}, ${st}.State)
        ${lastHeartbeat} = ${elapsed}
      }
      Start-Sleep -Seconds 4
    }
    ${st} = Get-ScheduledTask -TaskName ${taskName} -ErrorAction Stop
    if (${st}.State -eq 'Running') {
      Write-Warning ("Invoke-ExeAsSystem: task still Running after {0}m; killing." -f ${TimeoutMinutes})
      try { Stop-ScheduledTask -TaskName ${taskName} -ErrorAction SilentlyContinue } catch {}
      return [long]-2
    }
    # Surface captured stdout / stderr from the SYSTEM-side process before
    # returning. Doing this AFTER the task has stopped guarantees the cmd
    # redirect has been flushed and closed. The redirected logs live under
    # %TEMP%; we tail them to the caller's host and then leave the full
    # files on disk for post-mortem.
    foreach (${pair} in @(@{label='stdout';path=${stdoutLog}}, @{label='stderr';path=${stderrLog}})) {
      if (Test-Path -LiteralPath ${pair}.path) {
        ${sz} = (Get-Item -LiteralPath ${pair}.path).Length
        Write-Host ("[Invoke-ExeAsSystem] {0} {1} ({2:N0} bytes): {3}" -f ${taskName}, ${pair}.label, ${sz}, ${pair}.path)
        if (${sz} -gt 0) {
          Get-Content -LiteralPath ${pair}.path -Tail 40 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host ("  [{0}/{1}] {2}" -f ${taskName}, ${pair}.label, $_) }
        }
      }
    }
    # LastTaskResult is exposed as a UInt32 by PowerShell; values >= 0x80000000
    # (HRESULTs like 0x80070002 = ERROR_FILE_NOT_FOUND) overflow Int32 and
    # blow up an [int] cast. Use [long] so callers can compare to small
    # success codes (0, 3010) AND see the raw failure HRESULT verbatim.
    # NOTE: when we wrap via cmd.exe to redirect stdout/stderr, the
    # LastTaskResult is cmd.exe's exit code -- which happens to be the
    # inner exe's exit code in single-command (/c) mode.
    return [long](Get-ScheduledTaskInfo -TaskName ${taskName}).LastTaskResult
  } finally {
    try { Stop-ScheduledTask -TaskName ${taskName} -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Milliseconds 500
    Unregister-ScheduledTask -TaskName ${taskName} -Confirm:$false -ErrorAction SilentlyContinue
  }
}

Export-ModuleMember -Function @(
  'Start-ProvisionLog', 'Stop-ProvisionLog', 'Add-ToSystemPath', 'Confirm-Dir', 'Copy-Safe',
  'Get-FileSha256', 'Invoke-Exe', 'Invoke-ExeSilent', 'Expand-AnyArchive', 'Restart-ServiceLike',
  'Read-SimpleCsv2', 'Write-SimpleCsv2', 'Get-WorkingDir', 'Test-IsAdmin', 'Enable-NetFx3',
  'Invoke-ExeAsSystem',
  'Get-MastLogSessionDir', 'Get-MastSmokeDir', 'Get-MastVerifyDir'
)
