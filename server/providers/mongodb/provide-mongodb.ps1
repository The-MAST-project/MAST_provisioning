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

try {
  ${provLocal} = Join-Path ${PSScriptRoot} 'provisioning.psm1'
  ${provGlobal} = 'C:\ProgramData\MAST\provisioning.psm1'
  Import-Module (Test-Path ${provLocal} ? ${provLocal} : ${provGlobal}) -Force
} catch { Write-Warning "provisioning.psm1 import failed: $($_.Exception.Message)" }

function Show-Help {
@"
provide-mongodb.ps1 - Install MongoDB client tools from local assets

USAGE:
  .\provide-mongodb.ps1 [-AssetsRoot <path>] [-InstallRoot <dir>] [-NoCompass] [-Verbose] [-Help]
"@ | Write-Host
}
if (${Help}) { Show-Help; return }

# --- Logging ---
${LogRoot} = Join-Path ${env:ProgramData} 'MAST\logs'
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

function Invoke-Command {
  param([string]${FilePath}, [string]${Arguments}, [int[]]${OkCodes} = @(0), [string]${Tag} = "proc")
  Write-Verbose "${Tag}: ${FilePath} ${Arguments}"
  ${p} = Start-Process -FilePath ${FilePath} -ArgumentList ${Arguments} -PassThru -Wait -WindowStyle Hidden
  if (${OkCodes} -notcontains ${p}.ExitCode) { throw "${Tag} exit code ${p.ExitCode}" }
}

# --- Locate assets ---
${assets} = Join-Path ${AssetsRoot} 'mongodb\assets'
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
  Write-Host "Installing MongoDB Compass silently..."
  # Try common silent flags for Electron/NSIS installers
  ${argsList} = @(
    '/S',               # NSIS
    '/silent',          # Squirrel/Electron variants
    '/verysilent /norestart',
    '/quiet /norestart'
  )
  ${ok} = $false
  foreach (${a} in ${argsList}) {
    try {
      Invoke-Command -FilePath ${exeCompass} -Arguments ${a} -Tag "compass"
      ${ok} = $true
      break
    } catch {
      Write-Warning "Compass silent attempt failed with args: ${a}"
    }
  }
  if (-not ${ok}) { Write-Warning "Compass install may have failed silently. Check installer logs if available." }
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
