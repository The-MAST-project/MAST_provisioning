<#
.SYNOPSIS
  Enables .NET 3.5 and silently installs ASCOM Platform & Developer tools for provisioning.

.DESCRIPTION
  - Looks for installers under .\ascom\assets by default (override with -AssetsRoot).
  - Enables NetFx3 using Enable-WindowsOptionalFeature, then (if that fails under WinRM)
    a one-shot scheduled task running dism.exe as SYSTEM, then in-session DISM with media sources.
  - Installs:
      * AscomPlatform700.rc4.4448.exe
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

# --- Per-step timing ---
# ASCOM is the longest single step in the run (15-17 min observed). Two heavy
# sub-steps (NetFx3 DISM + ASCOM Platform installer with NGEN) used to be
# invisible inside that block. With these timers, the install log shows
# "STEP <name>: started" and "STEP <name>: NN.Ns" so we can target whichever
# is actually slow rather than guessing.
$Script:_stepStopwatch = $null
$Script:_stepName      = $null
function Start-Step {
  param([Parameter(Mandatory)][string]$Name)
  $Script:_stepName      = $Name
  $Script:_stepStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  Write-Host ("[ascom] STEP {0}: started at {1}" -f $Name, (Get-Date -Format 'HH:mm:ss'))
}
function Stop-Step {
  if (-not $Script:_stepStopwatch) { return }
  $Script:_stepStopwatch.Stop()
  $elapsed = $Script:_stepStopwatch.Elapsed
  Write-Host ("[ascom] STEP {0}: {1:N1}s ({2:hh\:mm\:ss})" -f $Script:_stepName, $elapsed.TotalSeconds, $elapsed)
  $Script:_stepName      = $null
  $Script:_stepStopwatch = $null
}

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
    [string]$LogTag = "proc",
    [int]$HeartbeatSeconds = 30
  )
  # Previously this used StandardOutput.ReadToEnd() + StandardError.ReadToEnd()
  # which are BLOCKING calls that don't return until the process exits. The
  # ASCOM Platform installer takes ~10 minutes (NGEN sweep) and inside that
  # window we had zero log output -- "stuck or working?" is unanswerable from
  # the host side. Switched to file-redirect + WaitForExit(intervalMs) polling
  # so we can emit a heartbeat line every $HeartbeatSeconds. stdout/stderr
  # files are kept under $LogRoot for post-mortem diagnostics.
  $safeTag    = $LogTag -replace '[^\w]', '_'
  $stdoutPath = Join-Path $LogRoot ("{0}.proc.stdout.log" -f $safeTag)
  $stderrPath = Join-Path $LogRoot ("{0}.proc.stderr.log" -f $safeTag)
  Write-Verbose "${LogTag}: $FilePath $Arguments"
  Write-Host ("[{0}] starting: {1} {2}" -f $LogTag, $FilePath, $Arguments)
  $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -NoNewWindow `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while (-not $p.WaitForExit($HeartbeatSeconds * 1000)) {
    Write-Host ("[{0}] still running, elapsed={1:N0}s, pid={2}" -f $LogTag, $sw.Elapsed.TotalSeconds, $p.Id)
  }
  try { $p.Refresh() } catch {}
  Write-Host ("[{0}] exited with code {1} after {2:N0}s" -f $LogTag, $p.ExitCode, $sw.Elapsed.TotalSeconds)
  $stdOut = (Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue)
  $stdErr = (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue)
  if ($stdOut) { Write-Verbose "$LogTag OUT: $stdOut" }
  if ($stdErr) { Write-Verbose "$LogTag ERR: $stdErr" }
  if ($null -ne $p.ExitCode -and $SuccessCodes -notcontains $p.ExitCode) {
    throw "$LogTag failed with exit code $($p.ExitCode). See $stdoutPath / $stderrPath."
  }
}

# SYSTEM-task helper was previously inlined here as Invoke-DismViaSystemTask.
# Extracted 2026-05-26 to provisioning.psm1::Invoke-ExeAsSystem so npcap and
# usbpcap can share the same battle-tested implementation. Thin wrapper kept
# for callsite readability and the dism.exe path lookup.
function Invoke-DismViaSystemTask {
  param(
    [Parameter(Mandatory)][string]$Arguments,
    [int]$TimeoutMinutes = 45
  )
  $dismExe = Join-Path $env:SystemRoot 'System32\dism.exe'
  if (-not (Test-Path -LiteralPath $dismExe)) { $dismExe = 'dism.exe' }
  return (Invoke-ExeAsSystem -Executable $dismExe -Arguments $Arguments `
            -TimeoutMinutes $TimeoutMinutes -TaskNamePrefix 'MAST-NetFx3')
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

  # Order matters: try ALL /Source-bound attempts first. Run #13 (2026-05-26)
  # showed that the online attempt "succeeds" but takes 12+ minutes pulling
  # from the WU CDN, so it was always winning over the bundled SxS attempt
  # that was correctly listed afterwards. Online attempt is the LAST-resort
  # fallback now.
  $dismTries = @()
  foreach ($src in ($candidateSources | Get-Unique)) {
    if (Test-Path -LiteralPath $src) {
      $dismTries += "/Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart /LimitAccess /Source:$src /Quiet"
    }
  }
  $dismTries += '/Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart /Quiet'

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
  # NetFx3 source-selection policy:
  #
  #   1. If the caller passed -FoDSource explicitly, honor it.
  #   2. Otherwise look for a bundled SxS at $assets\sxs\*.cab. Build-mast.ps1
  #      checks for these files at build time and fails the build if they
  #      are missing unless -AllowMissingNetFx3Sxs is passed. So when we get
  #      here in a production build, the bundle is guaranteed present.
  #   3. If neither (1) nor (2) yielded a source, fall back to online DISM
  #      ONLY because the dev/test override let the build skip the bundle.
  #      Log the path clearly so the operator knows which one ran. The
  #      online path is documented as less reliable and is the very path
  #      we are trying to avoid in production -- see
  #      assets/sxs/README.md.
  $netFx3Path = 'unknown'
  if (-not $FoDSource) {
    $bundledSxs = Join-Path $assets 'sxs'
    if (Test-Path -LiteralPath $bundledSxs) {
      $hasCab = @(Get-ChildItem -LiteralPath $bundledSxs -Filter '*.cab' -File -Recurse -ErrorAction SilentlyContinue).Count -gt 0
      if ($hasCab) {
        # Resolve to absolute path. The provider is invoked with
        # -AssetsRoot ".", so without resolution this would end up as
        # ".\sxs" and the SYSTEM-side DISM task would fail with
        # "Error: 0x800f081f / The source files could not be found"
        # because the task's WorkingDirectory is not where DISM thinks
        # it is. Run #14 (2026-05-26) showed this exactly -- bundled-sxs
        # attempt failed in <1s, online fallback then took 7+ minutes.
        $FoDSource = (Resolve-Path -LiteralPath $bundledSxs).Path
        $netFx3Path = 'bundled-sxs'
        Write-Host ("[ascom] NetFx3 source: bundled SxS at {0}" -f $FoDSource)
      }
    }
  } else {
    $FoDSource = (Resolve-Path -LiteralPath $FoDSource).Path
    $netFx3Path = 'explicit-FoDSource'
    Write-Host ("[ascom] NetFx3 source: explicit -FoDSource {0}" -f $FoDSource)
  }
  if ($netFx3Path -eq 'unknown') {
    $netFx3Path = 'online-DISM'
    Write-Warning "[ascom] NetFx3 source: no bundled SxS available -- falling back to online DISM (slower, depends on Windows Update CDN). This path is allowed only because the build was run with -AllowMissingNetFx3Sxs."
  }
  Start-Step ("netfx3-enable (" + $netFx3Path + ")")
  Enable-NetFx3Feature -FoDSource $FoDSource | Out-Null
  Stop-Step
} else {
  Write-Host "Skipping NetFx3 enablement (-NoNet)."
}

# --- Locate installers ---
$ascomPlatform = Get-InstallerPath -AssetsFolder $assets -BaseName "AscomPlatform700.rc4.4448"

if (-not $ascomPlatform) {
  Stop-Transcript | Out-Null
  throw "ASCOM Platform installer not found (expected 'AscomPlatform700.rc4.4448.*' under $assets)."
}

Write-Host "Found ASCOM Platform: $ascomPlatform"

# --- Installers (order: Platform -> Developer) ---
try {
  Start-Step 'ascom-platform-install'
  Install-Silent -InstallerPath $ascomPlatform -DisplayName "ASCOM Platform 7.0 RC4"
  Stop-Step
  Write-Host "ASCOM Platform installed."
} catch {
  Write-Warning "ASCOM Platform install failed: $($_.Exception.Message)"
  Stop-Transcript | Out-Null
  exit 1
}

Write-Host "Provisioning completed. Review log: $LogFile"
Stop-Transcript | Out-Null
exit 0
