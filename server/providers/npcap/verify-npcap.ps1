#requires -Version 5.1
[CmdletBinding()]
param()

# Verify that npcap installed successfully AND its kernel driver is registered.
# On failure, dump enough state to diagnose root cause without a second WinRM
# trip (we have been bitten by silent driver-install failures under WinRM
# network-logon tokens that strip BUILTIN\Administrators -- see
# DECISIONS.md notes on the 2026-05-25 run).

$ErrorActionPreference = 'Stop'
$logRoot   = Join-Path (Join-Path $env:SystemDrive 'MAST') 'logs'
$verifyLog = Join-Path $logRoot 'verify\npcap-verify.log'
$smokeFile = Join-Path $logRoot 'smoke\npcap-smoke.txt'
$null = New-Item -ItemType Directory -Force -Path (Split-Path $verifyLog -Parent), (Split-Path $smokeFile -Parent) -ErrorAction SilentlyContinue

function W { param([string]$Line) Add-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Line) }
Set-Content -LiteralPath $verifyLog -Encoding UTF8 -Value ("[{0}] verify-npcap.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$svc       = Get-Service -Name 'npcap' -ErrorAction SilentlyContinue
$drvPath   = 'C:\Windows\System32\Npcap\npcap.sys'
$drvExists = Test-Path -LiteralPath $drvPath

if ($svc -and $drvExists) {
    W ("PASS npcap Status={0} StartType={1} driver={2}" -f $svc.Status, $svc.StartType, $drvPath)
    Set-Content -Path $smokeFile -Encoding ASCII -Value 'npcap_ok'
    exit 0
}

# ---- failure path: dump diagnostics ----
W ("FAIL npcap svc={0} drvExists={1}" -f ($null -ne $svc), $drvExists)

W "--- elevation status of verify process ---"
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
W ("user={0}  isAdmin={1}  authType={2}  token-isElevated-via-principal={3}" `
    -f $identity.Name,
       $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator),
       $identity.AuthenticationType,
       $identity.IsAuthenticated)

W "--- C:\Windows\System32\Npcap\ contents (does install dir even exist?) ---"
$npcapDir = 'C:\Windows\System32\Npcap'
if (Test-Path -LiteralPath $npcapDir) {
    Get-ChildItem -LiteralPath $npcapDir -ErrorAction SilentlyContinue | ForEach-Object {
        W ("  {0,12} {1}" -f $_.Length, $_.Name)
    }
} else {
    W ("  ({0} does not exist; npcap installer likely never ran with admin token)" -f $npcapDir)
}

W "--- npcap install log tail (typical location) ---"
foreach ($p in @("$env:TEMP\NpcapInstaller.log", 'C:\Windows\Temp\NpcapInstaller.log', 'C:\Windows\Temp\npcap.log')) {
    if (Test-Path -LiteralPath $p) {
        W ("  log: {0} ({1} bytes)" -f $p, (Get-Item $p).Length)
        Get-Content -LiteralPath $p -Tail 12 -ErrorAction SilentlyContinue | ForEach-Object { W ("    {0}" -f $_) }
    }
}

W "--- recent SetupAPI driver-install errors (last 30 min) ---"
try {
    Get-WinEvent -FilterHashtable @{ LogName='Setup'; StartTime=(Get-Date).AddMinutes(-30) } -MaxEvents 20 -ErrorAction Stop |
        Where-Object { $_.LevelDisplayName -in @('Error','Warning') -and $_.Message -match 'npcap|driver' } |
        Select-Object -First 5 | ForEach-Object {
            W ("  {0} {1} {2}" -f $_.TimeCreated.ToString('HH:mm:ss'), $_.LevelDisplayName, (($_.Message -split "`r?`n")[0]))
        }
} catch {
    W ("  (could not read Setup event log: {0})" -f $_.Exception.Message)
}

exit 1
