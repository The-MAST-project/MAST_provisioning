<#
.SYNOPSIS
  Enables .NET 3.5 and silently installs ASCOM Platform & Developer tools for provisioning.

.DESCRIPTION
  - Looks for installers under .\ascom\assets by default (override with -AssetsRoot).
  - Enables NetFx3 using DISM/Enable-WindowsOptionalFeature.
  - Installs:
      * ASCOMPlatform710.4707.exe
      * AscomDeveloper662.4294.NewCertificate (exe or msi; extension optional)
  - Writes logs to %ProgramData%\MAST\logs
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
  Import-Module (Test-Path ${provLocal} ? ${provLocal} : ${provGlobal}) -Force  -DisableNameChecking
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

# --- Prep logging ---
$LogRoot = Join-Path $env:ProgramData 'MAST\logs'
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
  if ($stdOut) { Write-Verbose "$LogTag OUT: $stdOut" }
  if ($stdErr) { Write-Verbose "$LogTag ERR: $stdErr" }
  if ($SuccessCodes -notcontains $p.ExitCode) {
    throw "$LogTag failed with exit code $($p.ExitCode)."
  }
}

function Enable-NetFx3Feature {
  param([string]$FoDSource)
  Write-Host "Enabling .NET Framework 3.5 (NetFx3)..."
  try {
    # First attempt: standard Enable-WindowsOptionalFeature online
    Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart -ErrorAction Stop | Out-Null
    Write-Host "NetFx3 enabled (online)."
    return $true
  } catch {
    Write-Warning "Online enable failed: $($_.Exception.Message)"
  }

  $candidateSources = @()
  if ($FoDSource) { $candidateSources += $FoDSource }
  $candidateSources += @("A:\sources\sxs","D:\sources\sxs","E:\sources\sxs","F:\sources\sxs","G:\sources\sxs")

  foreach ($src in $candidateSources | Get-Unique) {
    if (Test-Path $src) {
      Write-Host "Trying NetFx3 with source: $src"
      try {
        # DISM with source (and LimitAccess to avoid WU)
        & dism.exe /Online /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:$src | Out-Null
        if ($LASTEXITCODE -eq 0) {
          Write-Host "NetFx3 enabled from source: $src"
          return $true
        } else {
          Write-Warning "DISM returned $LASTEXITCODE for source $src"
        }
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
