<#
.SYNOPSIS
  Provision MongoDB client tooling (mongosh, database tools, optional Compass) from local assets.

.PARAMETER AssetsRoot
  Root containing 'mongodb\assets' with the three files. Default: $PSScriptRoot.

.PARAMETER InstallRoot
  Base install folder. Default: 'C:\Program Files\MongoDB'

.PARAMETER NoCompass
  Skip installing MongoDB Compass.

.PARAMETER Help
  Show usage and exit.

.NOTES
  Expects:
    mongosh-2.2.6-win32-x64.zip
    mongodb-database-tools-windows-x86_64-100.9.4.zip
    mongodb-compass-1.43.0-win32-x64.exe (optional)
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]${AssetsRoot} = ${PSScriptRoot},
  [string]${InstallRoot} = 'C:\Program Files\MongoDB',
  [switch]${NoCompass},
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
provide-mongodb-client.ps1 - Install MongoDB client tools from local assets

USAGE:
  .\provide-mongodb-client.ps1 [-AssetsRoot <path>] [-InstallRoot <dir>] [-NoCompass] [-Verbose] [-Help]
"@ | Write-Host
}
if (${Help}) { Show-Help; return }

# --- Logging ---
${LogRoot} = Get-MastLogSessionDir
${null} = New-Item -ItemType Directory -Path ${LogRoot} -Force -ErrorAction SilentlyContinue
${LogFile} = Join-Path ${LogRoot} ("provide-mongodb_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path ${LogFile} -Append | Out-Null
Write-Verbose "Log: ${LogFile}"

# --- Helpers ---
function Confirm-Dir([string]${Path}) {
  if (-not (Test-Path ${Path})) { New-Item -ItemType Directory -Path ${Path} -Force | Out-Null }
}

function Add-ToSystemPath {
  param([Parameter(Mandatory)][string]${Dir})
  ${envKey} = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  ${pathVal} = (Get-ItemProperty -Path ${envKey} -Name PATH -ErrorAction SilentlyContinue).Path
  if (-not ${pathVal}) { ${pathVal} = '' }
  if (${pathVal} -notmatch [Regex]::Escape(${Dir})) {
    ${newPath} = (${pathVal}.TrimEnd(';') + ';' + ${Dir}).Trim(';')
    Set-ItemProperty -Path ${envKey} -Name PATH -Value ${newPath}
    # Broadcast WM_SETTINGCHANGE
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
    Write-Host "Added to PATH: ${Dir}"
  } else {
    Write-Verbose "PATH already contains ${Dir}"
  }
}

function ConvertFrom-Zip {
  param(
    [Parameter(Mandatory)][string]${ZipPath},
    [Parameter(Mandatory)][string]${Destination}
  )
  Write-Host "Extracting ${ZipPath} -> ${Destination}"
  Confirm-Dir ${Destination}
  Expand-Archive -Path ${ZipPath} -DestinationPath ${Destination} -Force
}

function Invoke-MongoClientExe {
  # Renamed from Invoke-Command -- the original name shadowed the built-in
  # cmdlet, which made it impossible to use real remoting from this script
  # and led to genuinely surprising bugs (a typo'd call would silently
  # dispatch to the built-in cmdlet instead).
  param([string]${FilePath}, [string]${Arguments}, [int[]]${OkCodes} = @(0), [string]${Tag} = "proc")
  Write-Verbose "${Tag}: ${FilePath} ${Arguments}"
  ${p} = Start-Process -FilePath ${FilePath} -ArgumentList ${Arguments} -PassThru -Wait -WindowStyle Hidden
  try { ${p}.Refresh() } catch {}
  if ($null -ne ${p}.ExitCode -and ${OkCodes} -notcontains ${p}.ExitCode) {
    throw ("{0} exit code {1}" -f ${Tag}, ${p}.ExitCode)
  }
}

# --- Locate assets ---
${assets} = ${AssetsRoot}
if (-not (Test-Path ${assets})) {
  Stop-Transcript | Out-Null
  throw "Assets folder not found: ${assets}"
}

${zipMongosh} = Join-Path ${assets} 'mongosh-2.2.6-win32-x64.zip'
${zipTools}   = Join-Path ${assets} 'mongodb-database-tools-windows-x86_64-100.9.4.zip'
${exeCompass} = Join-Path ${assets} 'mongodb-compass-1.43.0-win32-x64.exe'

if (-not (Test-Path ${zipMongosh})) { Stop-Transcript | Out-Null; throw "Missing: ${zipMongosh}" }
if (-not (Test-Path ${zipTools}))   { Stop-Transcript | Out-Null; throw "Missing: ${zipTools}" }
if (-not ${NoCompass} -and -not (Test-Path ${exeCompass})) {
  Write-Warning "Compass installer not found; continuing without Compass."
  ${NoCompass} = $true
}

# --- Install mongosh ---
${mongoshRoot} = Join-Path ${InstallRoot} 'mongosh\2.2.6'
ConvertFrom-Zip -ZipPath ${zipMongosh} -Destination ${mongoshRoot}

# Common zip layout: mongosh-2.2.6-win32-x64\bin\mongosh.exe
${mongoshBinGuess} = Join-Path ${mongoshRoot} 'mongosh-2.2.6-win32-x64\bin'
if (Test-Path ${mongoshBinGuess}) {
  ${mongoshBin} = ${mongoshBinGuess}
} else {
  # Fallback: search for mongosh.exe under extracted root
  ${mongoshExe} = Get-ChildItem -Path ${mongoshRoot} -Recurse -Filter 'mongosh.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not ${mongoshExe}) { Stop-Transcript | Out-Null; throw "mongosh.exe not found after extraction." }
  ${mongoshBin} = Split-Path -Parent ${mongoshExe}.FullName
}
Add-ToSystemPath -Dir ${mongoshBin}

# --- Install Database Tools ---
${toolsRoot} = Join-Path ${InstallRoot} 'tools\100.9.4'
ConvertFrom-Zip -ZipPath ${zipTools} -Destination ${toolsRoot}
# Typical layout: mongodb-database-tools-windows-x86_64-100.9.4\bin\mongoimport.exe etc.
${toolsBinGuess} = Join-Path ${toolsRoot} 'mongodb-database-tools-windows-x86_64-100.9.4\bin'
if (Test-Path ${toolsBinGuess}) {
  ${toolsBin} = ${toolsBinGuess}
} else {
  ${anyTool} = Get-ChildItem -Path ${toolsRoot} -Recurse -Filter 'mongoimport.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not ${anyTool}) { Stop-Transcript | Out-Null; throw "Database Tools 'bin' not found after extraction." }
  ${toolsBin} = Split-Path -Parent ${anyTool}.FullName
}
Add-ToSystemPath -Dir ${toolsBin}

# --- Install Compass (optional) ---
if (-not ${NoCompass}) {
  # MongoDB Compass ships as a Squirrel installer. Two facts make this hard
  # to provision under WinRM:
  #   1. The installer launches Compass.exe at the end of install and
  #      *waits for the GUI to exit* before returning. Under WinRM there
  #      is no interactive Window Station, so the GUI never exits and the
  #      installer never returns. Using Start-Process -Wait here blocks
  #      forever (we hit this on 2026-05-25, run #6: 60+ minutes stuck
  #      on this single step until the run was killed manually).
  #   2. The /S flag does install silently, but does NOT suppress that
  #      final GUI launch. Trying alternate silent flags (/silent,
  #      /verysilent) each ALSO hangs in -Wait, so a fallback loop is
  #      worse than useless -- the first hang ends the run.
  #
  # Lessons baked into this loop from run #8 (2026-05-26) where Compass
  # appeared on disk under app-1.43.0\ but the install was actually broken
  # (no wrapper at %LocalAppData%\MongoDBCompass\MongoDBCompass.exe, no
  # Start Menu entry):
  #
  #  1. Compass is Electron -- a single launch spawns a main MongoDBCompass.exe
  #     plus several renderer/GPU/utility helpers ALSO named MongoDBCompass.exe.
  #     Seeing many GUI PIDs is normal, NOT a sign the installer is hung or
  #     respawning. Do not use "GUI quiet" as a done-signal.
  #
  #  2. Squirrel.exe and Update.exe under %LocalAppData%\MongoDBCompass\ ARE
  #     the install machinery, not the GUI. The previous filter caught them
  #     by path and killed them mid-extraction; result was a partial install
  #     that fooled a lenient "any MongoDBCompass.exe on disk" verify. Now
  #     we only kill processes by NAME (MongoDBCompass, Compass); never by
  #     path-match.
  #
  #  3. The installer's post-extract step is "launch Compass with --squirrel-
  #     firstrun and wait for it to exit." Killing the GUI returns control to
  #     the installer, which then does its final shortcut/wrapper/uninstaller
  #     work and exits naturally. Done signal = installer process exited.
  #
  #  4. Verification must check BOTH the per-version binary (proves extraction
  #     reached the app-X.Y.Z stage) AND the wrapper at %LocalAppData%\
  #     MongoDBCompass\MongoDBCompass.exe (proves Squirrel's final pinning
  #     step ran -- this is what Start Menu and the uninstaller actually
  #     point at; without it the install is functionally broken even though
  #     bytes are on disk).
  Write-Host "Installing MongoDB Compass silently (non-blocking, GUI-only-kill loop)..."
  ${installer} = Start-Process -FilePath ${exeCompass} -ArgumentList '/S' `
      -PassThru -WindowStyle Hidden
  Write-Host ("  Compass installer PID={0}" -f ${installer}.Id)

  # Generous budget: a fresh Compass install can take 5-8 minutes to extract
  # ~250 MB on slow disks. We only force-kill the installer if it has not
  # exited by then; otherwise we wait for it to finish naturally.
  ${budgetSec}    = 600
  ${sw}           = [System.Diagnostics.Stopwatch]::StartNew()
  ${killedCount}  = 0

  while (${sw}.Elapsed.TotalSeconds -lt ${budgetSec}) {
    Start-Sleep -Seconds 2
    try { ${installer}.Refresh() } catch {}

    # Kill ONLY GUI processes, by NAME. Do not touch Squirrel/Update --
    # those are the installer machinery; killing them aborts the install.
    # @() wrap so PS 5.1 always returns an array (0-item -> $null without
    # this, which blows up .Count under StrictMode).
    ${guiProcs} = @(Get-Process -Name 'MongoDBCompass','Compass' -ErrorAction SilentlyContinue)
    foreach (${p} in ${guiProcs}) {
      try {
        Stop-Process -Id ${p}.Id -Force -ErrorAction Stop
        ${killedCount}++
        Write-Host ("  killed {0} PID={1}" -f ${p}.Name, ${p}.Id)
      } catch {
        Write-Warning ("  could not kill {0} PID={1}: {2}" -f ${p}.Name, ${p}.Id, $_.Exception.Message)
      }
    }

    ${installerAlive} = $false
    try { ${installerAlive} = -not ${installer}.HasExited } catch { ${installerAlive} = $false }
    if (-not ${installerAlive}) {
      Write-Host ("  installer exited naturally (elapsed={0:N0}s, killed={1} GUI procs)" -f ${sw}.Elapsed.TotalSeconds, ${killedCount})
      break
    }
  }

  if (${sw}.Elapsed.TotalSeconds -ge ${budgetSec}) {
    Write-Warning ("Compass installer did not exit within {0}s; force-killing PID={1}." -f ${budgetSec}, ${installer}.Id)
    try { Stop-Process -Id ${installer}.Id -Force -ErrorAction Stop } catch {}
  }

  # Final sweep: Electron may have respawned helpers between our last kill
  # and the installer's exit.
  Start-Sleep -Seconds 2
  foreach (${p} in @(Get-Process -Name 'MongoDBCompass','Compass' -ErrorAction SilentlyContinue)) {
    try { Stop-Process -Id ${p}.Id -Force -ErrorAction Stop } catch {}
  }

  # Verification: BOTH the wrapper AND the versioned extraction must exist.
  # Throwing on partial install is the right policy here -- a half-installed
  # Compass that bytes-exist-but-doesn't-launch is worse than a clean failure
  # the operator can re-trigger.
  ${compassRoot} = Join-Path ${env:LOCALAPPDATA} 'MongoDBCompass'
  ${wrapperExe}  = Join-Path ${compassRoot} 'MongoDBCompass.exe'
  ${appDirs}     = @(Get-ChildItem -LiteralPath ${compassRoot} -Directory -Filter 'app-*' -ErrorAction SilentlyContinue)
  ${haveWrapper} = Test-Path -LiteralPath ${wrapperExe}
  ${haveAppDir}  = (${appDirs}.Count -gt 0) -and (Test-Path -LiteralPath (Join-Path ${appDirs}[0].FullName 'MongoDBCompass.exe'))
  if (${haveWrapper} -and ${haveAppDir}) {
    Write-Host ("Compass installed: wrapper={0}, app={1}" -f ${wrapperExe}, ${appDirs}[0].FullName)
  } else {
    Write-Warning ("Compass install verification: wrapperExists={0}, appDirCount={1}, appDirHasExe={2}" `
        -f ${haveWrapper}, ${appDirs}.Count, ${haveAppDir})
    throw "MongoDB Compass install is incomplete. Expected wrapper at ${wrapperExe} and a populated app-* dir under ${compassRoot}."
  }
} else {
  Write-Verbose "Skipping Compass (-NoCompass)."
}

# --- Quick local checks (no server needed) ---
try {
  & (Join-Path ${mongoshBin} 'mongosh.exe') --nodb --eval "print(version())" | Out-Null
  & (Join-Path ${toolsBin} 'mongoimport.exe') --version | Out-Null
  Write-Host "mongosh and Database Tools appear installed."
} catch {
  Write-Warning "Client tool self-check failed: $($_.Exception.Message)"
}

Write-Host "MongoDB client provisioning complete. Log: ${LogFile}"
Stop-Transcript | Out-Null
exit 0
