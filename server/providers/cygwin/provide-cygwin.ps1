<#
.SYNOPSIS
  Unpacks a Cygwin tgz and finalizes the install for provisioning.

.DESCRIPTION
  - Looks for astrometry\assets\cygwin64.tgz (override with -AssetsRoot or -TgzPath).
  - Extracts to -InstallDir (default C:\cygwin64) using tar.exe.
  - Runs /etc/postinstall scripts if present.
  - Appends Cygwin bin to the system PATH (idempotent).
  - Logs to %ProgramData%\MAST\logs.

.PARAMETER AssetsRoot
  Root that contains 'astrometry\assets\cygwin64.tgz'. Default: $PSScriptRoot.

.PARAMETER TgzPath
  Explicit path to the tgz (overrides AssetsRoot discovery).

.PARAMETER InstallDir
  Target Cygwin root (default: C:\cygwin64).

.PARAMETER Help
  Show usage and exit.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]${AssetsRoot} = ${PSScriptRoot},
  [string]${TgzPath},
  [string]${InstallDir} = 'C:\cygwin64',
  [switch]${Help}
)

try {
  ${provLocal} = Join-Path ${PSScriptRoot} 'provisioning.psm1'
  ${provGlobal} = 'C:\ProgramData\MAST\provisioning.psm1'
  Import-Module (Test-Path ${provLocal} ? ${provLocal} : ${provGlobal}) -Force
} catch { Write-Warning "provisioning.psm1 import failed: $($_.Exception.Message)" }

function Show-Help {
@"
provide-cygwin.ps1 - Install Cygwin from cygwin64.tgz (WCD-ready)

USAGE:
  .\provide-cygwin.ps1 [-AssetsRoot <path>] [-TgzPath <file>] [-InstallDir <dir>] [-Verbose] [-Help]

NOTES:
  - Expects tar.exe on Windows (present on Windows 10/11). If missing, install the native tar feature or ship an extractor.
"@ | Write-Host
}

if (${Help}) { Show-Help; return }

# --- Logging ---
${LogRoot} = Join-Path ${env:ProgramData} 'MAST\logs'
${null} = New-Item -ItemType Directory -Path ${LogRoot} -Force -ErrorAction SilentlyContinue
${LogFile} = Join-Path ${LogRoot} ("provide-cygwin_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path ${LogFile} -Append | Out-Null

Write-Verbose "Log file: ${LogFile}"

# --- Locate tar.exe ---
${TarExe} = "${env:SystemRoot}\System32\tar.exe"
if (-not (Test-Path ${TarExe})) {
  Stop-Transcript | Out-Null
  throw "tar.exe not found at ${TarExe}. Provide an extractor or enable the Windows tar tool."
}

# --- Locate the tgz ---
if (-not ${TgzPath}) {
  ${TgzPath} = Join-Path ${AssetsRoot} 'astrometry\assets\cygwin64.tgz'
}
if (-not (Test-Path ${TgzPath})) {
  Stop-Transcript | Out-Null
  throw "Cygwin archive not found: ${TgzPath}"
}
Write-Host "Using archive: ${TgzPath}"

# --- Prepare install dir ---
try {
  if (-not (Test-Path ${InstallDir})) {
    New-Item -ItemType Directory -Path ${InstallDir} -Force | Out-Null
  }
} catch {
  Stop-Transcript | Out-Null
  throw "Failed to create install dir ${InstallDir}: $($_.Exception.Message)"
}

# --- Extract to a staging folder to handle archive root layout ---
${Staging} = Join-Path ${env:TEMP} ("cygwin64_stage_{0:yyyyMMdd_HHmmss}" -f (Get-Date))
New-Item -ItemType Directory -Path ${Staging} -Force | Out-Null

Write-Host "Extracting to staging: ${Staging}"
& ${TarExe} -x -z -f "${TgzPath}" -C "${Staging}"
if ($LASTEXITCODE -ne 0) {
  Stop-Transcript | Out-Null
  throw "Extraction failed with exit code ${LASTEXITCODE}."
}

# Determine actual root inside the archive
${CandidateRoot} = Join-Path ${Staging} 'cygwin64'
if (-not (Test-Path ${CandidateRoot})) {
  # maybe archive was a flat root; use staging itself
  ${CandidateRoot} = ${Staging}
}

# If InstallDir isn't empty, move aside (idempotent: only if empty we continue)
${existing} = Get-ChildItem -Path ${InstallDir} -Force -ErrorAction SilentlyContinue
if (${existing} -and ${existing}.Count -gt 0) {
  Write-Host "InstallDir ${InstallDir} is not empty; will overlay files."
}

# Copy into place
Write-Host "Copying Cygwin files to ${InstallDir}..."
robocopy "${CandidateRoot}" "${InstallDir}" /E /NFL /NDL /NJH /NJS /NP | Out-Null

# --- Postinstall: run any pending scripts ---
${Bash} = Join-Path ${InstallDir} 'bin\bash.exe'
${Dash} = Join-Path ${InstallDir} 'bin\dash.exe'   # fallback shell for some scripts
if (Test-Path ${Bash}) {
  # If there are *.sh without .done, execute them and mark as done
  ${PostDir} = Join-Path ${InstallDir} 'etc\postinstall'
  if (Test-Path ${PostDir}) {
    ${pending} = Get-ChildItem -Path ${PostDir} -Filter '*.sh' -File -ErrorAction SilentlyContinue
    if (${pending}) {
      Write-Host "Running Cygwin postinstall scripts..."
      ${cmd} = @'
set -e
shopt -s nullglob
for f in /etc/postinstall/*.sh; do
  if [ -f "$f" ] && [ ! -f "$f.done" ]; then
    /bin/dash "$f" || /bin/bash "$f"
    mv -f "$f" "$f.done" || true
  fi
done
'@
      & "${Bash}" -lc "${cmd}"
      if ($LASTEXITCODE -ne 0) {
        Write-Warning "Some postinstall scripts returned non-zero; check Cygwin logs."
      }
    } else {
      Write-Verbose "No pending postinstall scripts."
    }
  }
} else {
  Write-Warning "bash.exe not found under ${InstallDir}\bin. Postinstall scripts (if any) were not executed."
}

# --- PATH: ensure Cygwin bin is on the system PATH (idempotent) ---
function Add-ToSystemPath {
  param([Parameter(Mandatory)][string]${Dir})
  ${envKey} = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  ${pathVal} = (Get-ItemProperty -Path ${envKey} -Name PATH -ErrorAction SilentlyContinue).Path
  if (-not ${pathVal}) { ${pathVal} = '' }
  if (${pathVal} -notmatch [Regex]::Escape(${Dir})) {
    ${newPath} = (${pathVal}.TrimEnd(';') + ';' + ${Dir}).Trim(';')
    Set-ItemProperty -Path ${envKey} -Name PATH -Value ${newPath}
    # Broadcast WM_SETTINGCHANGE so new processes see it
    $signature = @"
using System;
using System.Runtime.InteropServices;
public class NativeMethods {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
  public static extern IntPtr SendMessageTimeout(IntPtr hWnd, int Msg, IntPtr wParam, string lParam, int fuFlags, int uTimeout, out IntPtr lpdwResult);
}
"@
    Add-Type -TypeDefinition $signature -ErrorAction SilentlyContinue | Out-Null
    [void][NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]0, 'Environment', 2, 5000, [ref]([IntPtr]::Zero))
    Write-Host "Added to PATH: ${Dir}"
  } else {
    Write-Verbose "PATH already contains ${Dir}"
  }
}
Add-ToSystemPath -Dir (Join-Path ${InstallDir} 'bin')

Write-Host "Cygwin deployment complete at ${InstallDir}. Log: ${LogFile}"
Stop-Transcript | Out-Null
exit 0
