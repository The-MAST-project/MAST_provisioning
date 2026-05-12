<#
.SYNOPSIS
  Enables .NET 3.5 and silently installs ASCOM Platform & Developer tools for provisioning.

.DESCRIPTION
  - Looks for installers under .\ascom\assets by default (override with -AssetsRoot).
  - Enables NetFx3 using Enable-WindowsOptionalFeature, then (if that fails under WinRM)
    a one-shot scheduled task running dism.exe as SYSTEM, then in-session DISM with media sources.
  - Installs:
      * ASCOMPlatform710.4707.exe
      * AscomDeveloper662.4294.NewCertificate (exe or msi; extension optional)
  - Writes logs under <SystemDrive>\MAST\logs\sessions\<timestamp>
  - Designed for WCD provisioning (unattended / no UI / no reboot).

.PARAMETER AssetsRoot
  Root folder containing the "ascom\assets" directory. Defaults to the script folder.

.PARAMETER FoDSource
  Optional Features-on-Demand (SxS) source path for NetFx3 (e.g., D:\sources\sxs).

.PARAMETER NoNet
  Skip NetFx3 enablement if specified.

.PARAMETER Help
  Show help/usage and exit.

.EXAMPLE
  .\provide-ascom.ps1 -Verbose

.EXAMPLE
  .\provide-ascom.ps1 -FoDSource "D:\sources\sxs"

#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$AssetsRoot = $PSScriptRoot,
  [string]$FoDSource,
  [switch]$NoNet,
  [switch]$Help
)

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
provide-ascom.ps1 - Silently provision ASCOM Platform & Developer tools and enable .NET 3.5

USAGE:
  .\provide-ascom.ps1 [-AssetsRoot <path>] [-FoDSource <path>] [-NoNet] [-Verbose] [-Help]

PARAMS:
  -AssetsRoot  Root containing 'ascom\assets'. Default: script folder.
  -FoDSource   Optional SxS/FoD path for NetFx3 (e.g., X:\sources\sxs). If omitted, will try online, then common media letters.
  -NoNet       Skip enabling .NET 3.5.
  -Verbose     Extra logs.
  -Help        This text.

NOTES:
  - Run as Administrator (WCD runs as SYSTEM).
  - No reboot is forced. If a reboot is required, the script returns a warning.
"@ | Write-Host
}

if ($Help) { Show-Help; return }

# execute-mast-provisioning.ps1 runs each module in a new powershell.exe; mast-log is not in scope unless
# provisioning.psm1 imported successfully. Always dot-source mast-log here (same pattern as other providers).
$mastLogDot = Join-Path $PSScriptRoot 'mast-log.ps1'
if (-not (Test-Path $mastLogDot)) { $mastLogDot = Join-Path $PSScriptRoot '..\..\lib\mast-log.ps1' }
if (-not (Test-Path $mastLogDot)) { throw "mast-log.ps1 not found (expected in staging next to this script or under server\lib)." }
. $mastLogDot

# --- Prep logging ---
$LogRoot = Get-MastLogSessionDir
$null = New-Item -ItemType Directory -Path $LogRoot -Force -ErrorAction SilentlyContinue
$LogFile = Join-Path $LogRoot ("provide-ascom_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $LogFile -Append | Out-Null

Write-Verbose "Log file: $LogFile"

# --- Helpers ---
function Test-Admin {
  try {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
  } catch { return $false }
}

if (-not (Test-Admin)) {
  Write-Warning "Not running elevated. In WCD this usually runs as SYSTEM (OK). If running manually, start PowerShell as Administrator."
}

function Invoke-Proc {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [string]$Arguments = "",
    [int[]]$SuccessCodes = @(0),
    [string]$LogTag = "proc"
  )
  Write-Verbose "${LogTag}: $FilePath $Arguments"
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo.FileName = $FilePath
  $p.StartInfo.Arguments = $Arguments
  $p.StartInfo.UseShellExecute = $false
  $p.StartInfo.RedirectStandardOutput = $true
  $p.StartInfo.RedirectStandardError  = $true
  $null = $p.Start()
  $stdOut = $p.StandardOutput.ReadToEnd()
  $stdErr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  try { $p.Refresh() } catch {}
  if ($stdOut) { Write-Verbose "$LogTag OUT: $stdOut" }
  if ($stdErr) { Write-Verbose "$LogTag ERR: $stdErr" }
  if ($null -ne $p.ExitCode -and $SuccessCodes -notcontains $p.ExitCode) {
    throw "$LogTag failed with exit code $($p.ExitCode)."
  }
}

function Invoke-DismViaSystemTask {
  param(
    [Parameter(Mandatory)][string]$Arguments,
    [int]$TimeoutMinutes = 45
  )
  # WinRM often returns "Access is denied" for Enable-WindowsOptionalFeature even for local
  # Administrators. A one-shot scheduled task running dism.exe as SYSTEM usually succeeds.
  $taskName = 'MAST-NetFx3-' + ([guid]::NewGuid().ToString('N').Substring(0, 12))
  $dismExe = Join-Path $env:SystemRoot 'System32\dism.exe'
  if (-not (Test-Path -LiteralPath $dismExe)) { $dismExe = 'dism.exe' }
  $action = New-ScheduledTaskAction -Execute $dismExe -Argument $Arguments
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::FromHours(2)) -MultipleInstances IgnoreNew
  try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
  } catch {
    Write-Warning "Could not register SYSTEM DISM task: $($_.Exception.Message)"
    return -1
  }
  try {
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
      $st = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
      if ($st.State -ne 'Running') { break }
      Start-Sleep -Seconds 4
    }
    $st = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    if ($st.State -eq 'Running') {
      Write-Warning "SYSTEM DISM task still Running after ${TimeoutMinutes}m."
      return -2
    }
    return [int](Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
  } finally {
    try { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Milliseconds 500
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  }
}

function Enable-NetFx3Feature {
  param([string]$FoDSource)
  Write-Host "Enabling .NET Framework 3.5 (NetFx3)..."
  try {
    Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart -ErrorAction Stop | Out-Null
    Write-Host "NetFx3 enabled (Enable-WindowsOptionalFeature online)."
    return $true
  } catch {
    Write-Warning "Enable-WindowsOptionalFeature failed: $($_.Exception.Message)"
  }

  $candidateSources = @()
  if ($FoDSource) { $candidateSources += $FoDSource }
  $candidateSources += @('A:\sources\sxs', 'D:\sources\sxs', 'E:\sources\sxs', 'F:\sources\sxs', 'G:\sources\sxs')

  $dismTries = @('/Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart /Quiet')
  foreach ($src in ($candidateSources | Get-Unique)) {
    if (Test-Path -LiteralPath $src) {
      $dismTries += "/Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart /LimitAccess /Source:$src /Quiet"
    }
  }

  foreach ($dismArgs in $dismTries) {
    Write-Host "Trying NetFx3 via SYSTEM scheduled task: dism.exe $dismArgs"
    $rc = Invoke-DismViaSystemTask -Arguments $dismArgs
    if ($rc -eq 0 -or $rc -eq 3010) {
      if ($rc -eq 3010) { Write-Warning "NetFx3: DISM reported success with exit 3010 (reboot may be required)." }
      else { Write-Host "NetFx3 enabled (SYSTEM DISM)." }
      return $true
    }
    Write-Warning "SYSTEM DISM exit $rc for: $dismArgs"
  }

  foreach ($src in ($candidateSources | Get-Unique)) {
    if (Test-Path -LiteralPath $src) {
      Write-Host "Trying NetFx3 in-session DISM with source: $src"
      try {
        & dism.exe /Online /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:$src | Out-Null
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010) {
          Write-Host "NetFx3 enabled from source (in-session): $src"
          return $true
        }
        Write-Warning "DISM returned $LASTEXITCODE for source $src"
      } catch {
        Write-Warning "DISM exception for ${src}: $($_.Exception.Message)"
      }
    }
  }

  Write-Warning "Failed to enable NetFx3. Continuing; ASCOM may still install if prerequisites are present."
  return $false
}

function Get-InstallerPath {
  param(
    [Parameter(Mandatory)][string]$AssetsFolder,
    [Parameter(Mandatory)][string]$BaseName # filename without extension or with known prefix
  )
  # Find either exact name or wildcard ignoring extension case
  $candidates = @()
  $candidates += Get-ChildItem -Path $AssetsFolder -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ieq $BaseName -or $_.BaseName -like "$BaseName*" }

  if (-not $candidates) { return $null }

  # Prefer .exe over .msi if both exist
  $exe = $candidates | Where-Object { $_.Extension -match '^\.exe$' } | Select-Object -First 1
  if ($exe) { return $exe.FullName }
  $msi = $candidates | Where-Object { $_.Extension -match '^\.msi$' } | Select-Object -First 1
  if ($msi) { return $msi.FullName }
  # Fallback to first
  return ($candidates | Select-Object -First 1).FullName
}

function Install-Silent {
  param(
    [Parameter(Mandatory)][string]$InstallerPath,
    [string]$DisplayName = "Package"
  )

  $ext = [IO.Path]::GetExtension($InstallerPath).ToLowerInvariant()
  $logArg = ""
  $pkgLog = Join-Path $LogRoot ("{0}_{1:yyyyMMdd_HHmmss}.install.log" -f ($DisplayName -replace '[^\w\-]','_'), (Get-Date))

  if ($ext -eq ".msi") {
    # MSI silent
    $args = "/i `"$InstallerPath`" /qn /norestart /L*v `"$pkgLog`""
    Invoke-Proc -FilePath "msiexec.exe" -Arguments $args -LogTag $DisplayName
  } else {
    # EXE silent - try common flags used by Inno/NSIS/MSI-bootstrappers
    # Prefer very silent & no reboot; suppress msg boxes; log if supported.
    $exeArgsTry = @(
      "/s"
    )
    $lastErr = $null
    foreach ($a in $exeArgsTry) {
      try {
        Invoke-Proc -FilePath $InstallerPath -Arguments $a -LogTag $DisplayName
        return
      } catch {
        $lastErr = $_
        Write-Warning "$DisplayName silent attempt failed with args: $a"
      }
    }
    if ($lastErr) { throw $lastErr }
  }
}

# --- Resolve assets folder ---
$assets = $AssetsRoot
if (-not (Test-Path $assets)) {
  Stop-Transcript | Out-Null
  throw "Assets folder not found: $assets"
}
Write-Host "Using assets folder: $assets"

# --- Enable .NET 3.5 (unless skipped) ---
if (-not $NoNet) {
  Enable-NetFx3Feature -FoDSource $FoDSource | Out-Null
} else {
  Write-Host "Skipping NetFx3 enablement (-NoNet)."
}

# --- Locate installers ---
$ascomPlatform = Get-InstallerPath -AssetsFolder $assets -BaseName "ASCOMPlatform710.4707"

if (-not $ascomPlatform) {
  Stop-Transcript | Out-Null
  throw "ASCOM Platform installer not found (expected 'ASCOMPlatform710.4707.*' under $assets)."
}

Write-Host "Found ASCOM Platform: $ascomPlatform"

# --- Installers (order: Platform -> Developer) ---
try {
  Install-Silent -InstallerPath $ascomPlatform -DisplayName "ASCOM Platform 7.1.0"
  Write-Host "ASCOM Platform installed."
} catch {
  Write-Warning "ASCOM Platform install failed: $($_.Exception.Message)"
  Stop-Transcript | Out-Null
  exit 1
}

Write-Host "Provisioning completed. Review log: $LogFile"
Stop-Transcript | Out-Null
exit 0
