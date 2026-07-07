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
  [switch]${Help},
  # Reinstall even if the client tools are already present (otherwise the
  # ~720s Compass install + the zip re-extracts are skipped).
  [switch]${Force}
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

# Idempotent skip: if mongosh is already installed (and Compass too, unless
# -NoCompass), skip the zip re-extracts + the long Compass installer. This is a
# stronger check than verify (which only re-detects mongosh), so a skip is safe.
# Use -Force to reinstall.
${mongoshFound} = Get-ChildItem -Path (Join-Path ${InstallRoot} 'mongosh') -Recurse -Filter 'mongosh.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
${compassOk}    = ${NoCompass} -or (Test-Path (Join-Path ${env:LOCALAPPDATA} 'MongoDBCompass\MongoDBCompass.exe'))
if (-not ${Force} -and ${mongoshFound} -and ${compassOk}) {
    Write-Host ("MongoDB client already installed (mongosh{0}); skipping. Use -Force to reinstall." -f $(if (-not ${NoCompass}) { ' + Compass' } else { '' }))
    Stop-Transcript | Out-Null
    exit 0
}

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
  # Lessons baked into this loop from runs #6-#9 (2026-05-25 .. 2026-05-26),
  # where the previous strategies all produced a half-installed Compass:
  #
  #  Run #8 broke by killing Squirrel/Update by path-match (those are the
  #  installer machinery, not the GUI -- killing them aborted extraction
  #  mid-flight). Fix: kill ONLY by name (MongoDBCompass / Compass).
  #
  #  Run #9 (current strategy before this patch) killed Compass.exe the
  #  *instant* it appeared. Installer exited in 12s and the wrapper file
  #  showed up, but no Start Menu shortcut existed afterwards. Root cause:
  #  Squirrel uses Compass's --squirrel-firstrun handler to register
  #  shortcuts and uninstaller entries. Killing Compass before that handler
  #  ran left the install missing user-visible pieces even though files
  #  were on disk.
  #
  #  This strategy: phase the loop so we give Compass's --squirrel-firstrun
  #  handler the ~30s it typically needs before we kill anything. The
  #  installer is then allowed to exit naturally on its own. We only
  #  force-kill GUI processes once extraction has clearly completed AND
  #  the firstrun handler has had time to register itself.
  #
  #  Note: Compass is Electron, so a single "launch" spawns a main
  #  MongoDBCompass.exe plus several renderer/GPU/utility helpers ALSO
  #  named MongoDBCompass.exe. Seeing many PIDs at once is normal.
  Write-Host "Installing MongoDB Compass silently (phased non-blocking loop)..."
  ${installer} = Start-Process -FilePath ${exeCompass} -ArgumentList '/S' `
      -PassThru -WindowStyle Hidden
  Write-Host ("  Compass installer PID={0}" -f ${installer}.Id)

  ${waitForGuiSec}   = 240   # phase 1: wait up to 4 min for Compass to launch
  # phase 2: let --squirrel-firstrun do its work. Bumped 30s -> 90s after
  # run #10 (2026-05-26) where extraction completed cleanly (177MB exe, 360MB
  # app dir, wrapper present) but the Start Menu shortcut was missing -- 30s
  # was not enough for Squirrel's shortcut-registration step to finish.
  ${firstrunGraceSec}= 90
  ${killBudgetSec}   = 300   # phase 3: from start of kill loop until force-kill
  ${overallBudgetSec}= 720   # absolute wall clock from installer start

  ${sw}    = [System.Diagnostics.Stopwatch]::StartNew()
  ${guiAppeared}    = $false
  ${guiAppearedAt}  = $null

  # ----- Phase 1: wait for the GUI to appear (proves extraction reached
  # the "launch the app for firstrun" stage). Do NOT kill anything here.
  while (${sw}.Elapsed.TotalSeconds -lt ${waitForGuiSec}) {
    try { ${installer}.Refresh() } catch {}
    ${gui} = @(Get-Process -Name 'MongoDBCompass','Compass' -ErrorAction SilentlyContinue)
    if (${gui}.Count -gt 0) {
      ${guiAppeared}   = $true
      ${guiAppearedAt} = ${sw}.Elapsed.TotalSeconds
      Write-Host ("  Compass GUI launched at t={0:N0}s (PID(s)={1})" -f ${guiAppearedAt}, ((${gui}.Id) -join ','))
      break
    }
    if (${installer}.HasExited) {
      Write-Warning ("  Installer exited at t={0:N0}s WITHOUT launching Compass -- extraction may have failed." -f ${sw}.Elapsed.TotalSeconds)
      break
    }
    Start-Sleep -Seconds 2
  }
  if (-not ${guiAppeared} -and -not ${installer}.HasExited) {
    Write-Warning ("  Compass GUI never appeared within {0}s; killing installer." -f ${waitForGuiSec})
    try { Stop-Process -Id ${installer}.Id -Force -ErrorAction Stop } catch {}
  }

  # ----- Phase 2: grace period. Compass's --squirrel-firstrun handler
  # writes Start Menu shortcut, registers protocol handlers, writes
  # uninstaller registry entries. Empirically completes in <10s on the
  # dev VM; we give 30s for safety. Do NOT kill during this window.
  if (${guiAppeared}) {
    Write-Host ("  Phase 2: firstrun grace ({0}s) so Squirrel can register shortcut/registry..." -f ${firstrunGraceSec})
    Start-Sleep -Seconds ${firstrunGraceSec}
  }

  # ----- Phase 3: kill GUI to unblock the installer's wait-for-app-exit;
  # then wait for the installer to exit naturally. The installer's final
  # work after the GUI exits (cleanup, finalize) is usually <5s.
  ${killStartSec} = ${sw}.Elapsed.TotalSeconds
  ${killedCount}  = 0
  Write-Host ("  Phase 3: kill GUI + wait for installer exit (budget={0}s)..." -f ${killBudgetSec})
  while (${sw}.Elapsed.TotalSeconds -lt (${killStartSec} + ${killBudgetSec}) -and
         ${sw}.Elapsed.TotalSeconds -lt ${overallBudgetSec}) {
    try { ${installer}.Refresh() } catch {}
    ${gui} = @(Get-Process -Name 'MongoDBCompass','Compass' -ErrorAction SilentlyContinue)
    foreach (${p} in ${gui}) {
      try {
        Stop-Process -Id ${p}.Id -Force -ErrorAction Stop
        ${killedCount}++
        Write-Host ("    killed {0} PID={1}" -f ${p}.Name, ${p}.Id)
      } catch {
        Write-Warning ("    could not kill {0} PID={1}: {2}" -f ${p}.Name, ${p}.Id, $_.Exception.Message)
      }
    }
    if (${installer}.HasExited) {
      Write-Host ("  installer exited naturally (total elapsed={0:N0}s, killed={1} GUI procs)" -f ${sw}.Elapsed.TotalSeconds, ${killedCount})
      break
    }
    Start-Sleep -Seconds 2
  }

  if (-not ${installer}.HasExited) {
    Write-Warning ("Compass installer still running at t={0:N0}s; force-killing PID={1}." -f ${sw}.Elapsed.TotalSeconds, ${installer}.Id)
    try { Stop-Process -Id ${installer}.Id -Force -ErrorAction Stop } catch {}
  }

  # Final sweep.
  Start-Sleep -Seconds 2
  foreach (${p} in @(Get-Process -Name 'MongoDBCompass','Compass' -ErrorAction SilentlyContinue)) {
    try { Stop-Process -Id ${p}.Id -Force -ErrorAction Stop } catch {}
  }

  # Verification: wrapper + app dir + extracted app size + Start Menu shortcut
  # all must be present. Bare existence is not enough -- run #9 had wrapper
  # and app dir but no shortcut; the install was functionally broken.
  ${compassRoot}   = Join-Path ${env:LOCALAPPDATA} 'MongoDBCompass'
  ${wrapperExe}    = Join-Path ${compassRoot} 'MongoDBCompass.exe'
  ${appDirs}       = @(Get-ChildItem -LiteralPath ${compassRoot} -Directory -Filter 'app-*' -ErrorAction SilentlyContinue)
  ${haveWrapper}   = Test-Path -LiteralPath ${wrapperExe}
  ${appExeBytes}   = 0
  ${appDirBytes}   = 0
  ${appDirPath}    = $null
  if (${appDirs}.Count -gt 0) {
    ${appDirPath} = ${appDirs}[0].FullName
    ${appExe}     = Join-Path ${appDirPath} 'MongoDBCompass.exe'
    if (Test-Path -LiteralPath ${appExe}) {
      ${appExeBytes} = (Get-Item -LiteralPath ${appExe}).Length
    }
    ${appDirBytes} = (Get-ChildItem -LiteralPath ${appDirPath} -Recurse -File -ErrorAction SilentlyContinue |
                       Measure-Object -Property Length -Sum).Sum
  }

  # Start Menu shortcut: Squirrel writes a .lnk somewhere under the user's
  # or all-users Start Menu Programs dir. Path varies by Squirrel version
  # ("MongoDB Inc\" subfolder or not, "MongoDB Compass" vs "Compass" name).
  # Search recursively across both user-scope and machine-scope Start Menu
  # roots and accept any .lnk whose name matches /compass/i. Log everything
  # found (or empty result) so we have actionable data if we miss again.
  ${startMenuRoots} = @(
    (Join-Path ${env:APPDATA}     'Microsoft\Windows\Start Menu'),
    (Join-Path ${env:ProgramData} 'Microsoft\Windows\Start Menu')
  ) | Where-Object { Test-Path -LiteralPath $_ }
  ${shortcutHits} = @()
  foreach (${root} in ${startMenuRoots}) {
    ${found} = @(Get-ChildItem -LiteralPath ${root} -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match 'compass' })
    if (${found}.Count -gt 0) { ${shortcutHits} += ${found} }
  }
  Write-Host ("Compass shortcut search: roots=[{0}] hits={1}" -f (${startMenuRoots} -join ' ; '), ${shortcutHits}.Count)
  foreach (${h} in ${shortcutHits}) { Write-Host ("  found: {0}" -f ${h}.FullName) }
  ${shortcutPath} = if (${shortcutHits}.Count -gt 0) { ${shortcutHits}[0].FullName } else { $null }
  ${haveShortcut} = $null -ne ${shortcutPath}

  Write-Host ("Compass verify: wrapper={0} appDir={1} appExeBytes={2:N0} appDirBytes={3:N0} shortcut={4}" `
      -f ${haveWrapper}, ${appDirPath}, ${appExeBytes}, ${appDirBytes}, $(if (${haveShortcut}) { ${shortcutPath} } else { '<missing>' }))

  ${issues} = @()
  if (-not ${haveWrapper})              { ${issues} += "wrapper missing at ${wrapperExe}" }
  if ($null -eq ${appDirPath})          { ${issues} += "no app-* dir under ${compassRoot}" }
  if (${appExeBytes} -lt 100000000)     { ${issues} += ("app exe too small ({0} bytes; expect >100MB)" -f ${appExeBytes}) }
  if (${appDirBytes} -lt 200000000)     { ${issues} += ("app dir too small ({0} bytes total; expect >200MB)" -f ${appDirBytes}) }
  if (-not ${haveShortcut})             { ${issues} += "no Start Menu shortcut at any expected path" }

  if (${issues}.Count -gt 0) {
    throw ("MongoDB Compass install is incomplete: " + (${issues} -join '; '))
  }
  Write-Host "Compass install verified."
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
