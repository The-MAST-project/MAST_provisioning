<#
.SYNOPSIS
  Prepare a Windows client for MAST: set name, create 'mast' admin (prompted password), and enable secure remoting.

.DESCRIPTION
  This script:
    - takes a HostName parameter and renames the computer if needed
    - creates a local user 'mast' and adds it to Administrators (prompts for password if user missing)
    - sets that account's display name (FullName) to 'mast' so Windows Settings shows 'mast', not e.g. 'user'
    - enables PowerShell Remoting (WinRM), creates a self-signed cert for HTTPS listener, opens firewall ports
    - optionally adds a provider IP/DNS to WSMan TrustedHosts
    - does NOT change network settings (DHCP remains)

.NOTES
  - Run this script AS ADMINISTRATOR on the target machine.
  - If you request a reboot after renaming (-Reboot), the machine will restart and further actions will not run until next boot.
  - This script prefers Desktop PowerShell cmdlets (Get-LocalUser / New-LocalUser); it contains fallbacks using net.exe for older OS variants.
  - When env MAST_RUN_ID is set (run-remote-script-winrm.py), slmgr /rearm is skipped so WinRM can complete; run rearm locally if needed.
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [Parameter(Mandatory=$true, Position=0)]
  [ValidatePattern('^[A-Za-z0-9-]{1,15}$')]
  [string]$HostName,

  [Parameter(Mandatory=$false)]
  [string]$Provider,   # optional provider IP/DNS to add to TrustedHosts

  [Parameter(Mandatory=$false)]
  [Alias('h','?')]
  [switch]$Help,       # show help and exit

  [switch]$Reboot      # restart immediately if computer name changed
)

$ErrorActionPreference = 'Stop'

function Show-Help {
  $exe = (Split-Path -Leaf $MyInvocation.MyCommand.Path)
  @"
USAGE:
  .\{0} -HostName <NAME> [-Provider <IP-or-DNS>] [-Reboot] [-Help]

PARAMETERS:
  -HostName   (required)  : Desired computer name. Allowed chars: letters, numbers, hyphen. Max 15 chars.
  -Provider   (optional)  : IP or DNS name of your provider machine to add to WSMan TrustedHosts.
  -Reboot     (switch)    : If present and the name is changed, reboot immediately to apply the new name.
  -Help|-h|-? (switch)    : Show this help text and exit.

EXAMPLES:
  # Set name to EDGE-001, add provider, ask for mast password if needed (no immediate reboot)
  .\{0} -HostName EDGE-001 -Provider 192.168.63.10

  # Set name and reboot immediately so the name takes effect now
  .\{0} -HostName EDGE-002 -Reboot

NOTES / BEHAVIOUR:
  - The script will prompt interactively for the mast password only if the 'mast' user does not already exist.
  - Network configuration is NOT modified; DHCP remains in place.
  - The script attempts to use modern LocalAccounts cmdlets; if they are not available it falls back to 'net user' and 'net localgroup' commands.
  - Run the script as Administrator. If you forgot, right-click PowerShell and choose "Run as Administrator".
"@ -f $exe
}

function Write-Headline($text) {
  Write-Host "`n=== $text ===" -ForegroundColor Cyan
}

function Get-CurrentComputerName {
  try { return (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Name } catch { return $env:COMPUTERNAME }
}

function Ensure-ComputerName {
  param([string]$NewName, [switch]$Reboot)
  $current = Get-CurrentComputerName
  if ($current -ieq $NewName) {
    Write-Host "Computer name already '$current' -- no change needed."
    return $false
  }

  Write-Headline "Setting computer name to '$NewName' (current: '$current')"
  try {
    Rename-Computer -NewName $NewName -Force -ErrorAction Stop
    Write-Host "Rename scheduled. A reboot is required to complete the change."
    if ($Reboot) {
      Write-Host "Rebooting now..." -ForegroundColor Yellow
      Restart-Computer -Force
      # script will stop here due to reboot
    }
    return $true
  } catch {
    Write-Error "Failed to rename computer: $($_.Exception.Message)"
    throw
  }
}

function Try-GetLocalUser {
  param([string]$UserName)
  # prefer Get-LocalUser if available
  if (Get-Command -Name Get-LocalUser -ErrorAction SilentlyContinue) {
    return Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
  } else {
    # fallback: parse 'net user' output
    $out = net user $UserName 2>$null
    if ($LASTEXITCODE -eq 0) { return @{ Name = $UserName } } else { return $null }
  }
}

function Set-LocalUserDisplayName {
  param(
    [string]$UserName,
    [string]$DisplayName
  )
  if (Get-Command -Name Set-LocalUser -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $UserName -FullName $DisplayName -ErrorAction Stop
  } else {
    $proc = Start-Process -FilePath net -ArgumentList "user", $UserName, ("/fullname:{0}" -f $DisplayName) -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "Failed to set account display name with net user (code $($proc.ExitCode))." }
  }
}

function Create-LocalUser {
  param(
    [string]$UserName,
    [System.Security.SecureString]$SecurePassword,
    [string]$DisplayName
  )
  if (Get-Command -Name New-LocalUser -ErrorAction SilentlyContinue) {
    New-LocalUser -Name $UserName `
                  -Password $SecurePassword `
                  -FullName $DisplayName `
                  -PasswordNeverExpires:$true `
                  -AccountNeverExpires:$true `
                  -UserMayNotChangePassword:$false -ErrorAction Stop
  } else {
    # fallback using 'net user' which requires converting secure string to plaintext temporarily
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $proc = Start-Process -FilePath net -ArgumentList "user", $UserName, $plain, "/add", ("/fullname:{0}" -f $DisplayName) -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "Failed to create local user with net user (code $($proc.ExitCode))." }
    # set account to never expires (if supported)
    Start-Process -FilePath net -ArgumentList "user", $UserName, "/expires:never" -NoNewWindow -Wait | Out-Null
  }
}

function Ensure-LocalAdminUser {
  param(
    [string]$UserName = 'mast',
    [string]$DisplayName = 'mast'
  )
  Write-Headline "Ensuring local admin user '$UserName' exists"
  $user = Try-GetLocalUser -UserName $UserName
  if ($null -ne $user) {
    Write-Host "User '$UserName' already exists."
  } else {
    Write-Host "User '$UserName' not found. You will be prompted for a password to create it."
    $securePw = Read-Host -AsSecureString "Enter password for local user '$UserName' (input hidden)"
    if (-not $securePw) { throw "No password entered; aborting user creation." }
    Create-LocalUser -UserName $UserName -SecurePassword $securePw -DisplayName $DisplayName
    Write-Host "User '$UserName' created."
  }

  # Friendly name shown in Settings / login screen (FullName) is separate from the account name (SAM).
  try {
    Set-LocalUserDisplayName -UserName $UserName -DisplayName $DisplayName
    Write-Host "Account display name set to '$DisplayName'."
  } catch {
    Write-Warning "Could not set account display name: $($_.Exception.Message)"
  }

  # Ensure the user is in Administrators group
  try {
    if (Get-Command -Name Add-LocalGroupMember -ErrorAction SilentlyContinue) {
      $isMember = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match "^(?:$env:COMPUTERNAME\\)?$UserName$" -or $_.Name -match "^(?:\.)\\$UserName$"
      }
      if (-not $isMember) {
        Add-LocalGroupMember -Group 'Administrators' -Member $UserName -ErrorAction Stop
        Write-Host "Added '$UserName' to Administrators."
      } else {
        Write-Host "'$UserName' is already a member of Administrators."
      }
    } else {
      # fallback to 'net localgroup'
      $check = net localgroup Administrators | Select-String -Pattern "^\s*$UserName\b" -SimpleMatch
      if (-not $check) {
        Start-Process -FilePath net -ArgumentList "localgroup", "Administrators", $UserName, "/add" -NoNewWindow -Wait | Out-Null
        Write-Host "Added '$UserName' to Administrators (via net localgroup)."
      } else {
        Write-Host "'$UserName' is already a member of Administrators."
      }
    }
  } catch {
    Write-Warning "Could not verify/add user to Administrators: $($_.Exception.Message)"
  }
}

function Test-MastHttpsListenerPresent {
  try {
    $rows = @(Get-WSManInstance -ResourceURI winrm/config/Listener -Enumerate -ErrorAction Stop)
    foreach ($r in $rows) {
      if ($r.Transport -eq 'HTTPS') { return $true }
    }
    return $false
  } catch {
    return $false
  }
}

function Initialize-MastWinRmFirewallAndRemoting {
  Write-Headline "Enabling PowerShell Remoting (WinRM) and configuring firewall"

  # Invoked via tools/run-remote-script-winrm.py (sets MAST_RUN_ID): avoid Enable-PSRemoting
  # when listeners already exist — recycling WinRM mid-run drops the active session.
  $mastRemote = [bool]$env:MAST_RUN_ID
  $mastSkipEnablePsRemoting = $false
  if ($mastRemote) {
    try {
      $svc = Get-Service WinRM -ErrorAction Stop
      $listeners = @(Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue)
      if ($svc.Status -eq 'Running' -and $listeners.Count -gt 0) {
        $mastSkipEnablePsRemoting = $true
        Write-Host "MAST_RUN_ID set and WinRM listeners already present -- skipping Enable-PSRemoting (keeps current WinRM session alive)."
      }
    } catch {}
  }

  if (-not $mastSkipEnablePsRemoting) {
    try {
      # WSMan refuses some operations when any profile is Public.
      try { Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private } catch {}
      Enable-PSRemoting -SkipNetworkProfileCheck -Force -ErrorAction Stop
    } catch {
      Write-Warning "Enable-PSRemoting had a problem: $($_.Exception.Message) -- continuing."
    }
  }

  # Ensure firewall rules for WinRM (HTTP and HTTPS)
  foreach ($port in 5985,5986) {
    $ruleName = "MAST - WinRM port $port"
    if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
      New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -Profile Any | Out-Null
    } else {
      Set-NetFirewallRule -DisplayName $ruleName -Enabled True | Out-Null
    }
  }

  # Enable common groups used by remoting/admin shares
  foreach ($group in "File and Printer Sharing","Remote Service Management","Windows Remote Management") {
    try { Set-NetFirewallRule -DisplayGroup $group -Enabled True -Profile Any -ErrorAction SilentlyContinue | Out-Null } catch {}
  }

  # Allow local admin credentials over network (avoid UAC token filtering)
  New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ErrorAction SilentlyContinue | Out-Null
  New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
                  -Name "LocalAccountTokenFilterPolicy" -Value 1 -PropertyType DWord -Force | Out-Null
}

function Emit-PrepareSafeCompleteSignal {
  param([string]$ComputerHostName)
  $rid = if ($env:MAST_RUN_ID) { $env:MAST_RUN_ID } else { 'n/a' }
  # Orchestrator (run-remote-script-winrm.py) mirrors ##MAST## lines to stderr as [guest].
  # Emit immediately before optional HTTPS listener / winrm.cmd work (last stage).
  Write-Host ("##MAST## kind=prepare_safe_complete run_id={0} computer={1} host_name_param={2}" -f $rid, $env:COMPUTERNAME, $ComputerHostName)
  try { [Console]::Out.Flush() } catch {}
}

function Install-MastWinRmHttpsListener {
  param(
    [Parameter(Mandatory=$true)]
    [string]$PrimaryHostName
  )

  if (Test-MastHttpsListenerPresent) {
    Write-Headline "WinRM HTTPS listener"
    Write-Host "HTTPS listener already present -- skipping certificate/listener creation."
    return
  }

  Write-Headline "Creating self-signed certificate and configuring WinRM HTTPS listener (final operation)"

  try {
    $activeName = $env:COMPUTERNAME
    try {
      $activeName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
    } catch {}

    $dnsNames = @($activeName)
    if ($PrimaryHostName) { $dnsNames += $PrimaryHostName }
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
      ForEach-Object { $dnsNames += $_.IPAddress }
    $dnsNames = $dnsNames | Where-Object { $_ } | Select-Object -Unique

    $cert = New-SelfSignedCertificate -DnsName $dnsNames -CertStoreLocation Cert:\LocalMachine\My -KeyLength 2048 -NotAfter (Get-Date).AddYears(5) -ErrorAction Stop

    # IMPORTANT: WSMan:\ New-Item/Remove-Item can hang on some Windows builds.
    # Use winrm.cmd create/delete instead (can recycle WinRM — runs last, after prepare_safe_complete).
    try { & winrm.cmd delete winrm/config/Listener?Address=*+Transport=HTTPS 2>$null | Out-Null } catch {}
    $createArg = "@{Hostname=`"$activeName`";CertificateThumbprint=`"$($cert.Thumbprint)`"}"
    & winrm.cmd create winrm/config/Listener?Address=*+Transport=HTTPS $createArg 2>&1 | Out-Null
    Set-Service WinRM -StartupType Automatic
    if ((Get-Service WinRM -ErrorAction SilentlyContinue).Status -ne 'Running') { Start-Service WinRM -ErrorAction SilentlyContinue }
    Write-Host "WinRM HTTPS listener created (cert thumbprint: $($cert.Thumbprint))."
  } catch {
    Write-Warning "Failed to create WinRM HTTPS listener or certificate: $($_.Exception.Message)"
  }
}

function Set-TrustedHostsIfNeeded {
  param([string]$Provider)
  if (-not $Provider) { return }
  Write-Headline "Adding '$Provider' to WSMan TrustedHosts"
  $path = 'WSMan:\localhost\Client\TrustedHosts'
  try {
    $existing = (Get-Item -Path $path -ErrorAction SilentlyContinue).Value
    if ($existing -and $existing -notmatch [regex]::Escape($Provider)) {
      Set-Item -Path $path -Value ($existing + "," + $Provider) -Force
    } elseif (-not $existing) {
      Set-Item -Path $path -Value $Provider -Force
    } else {
      Write-Host "'$Provider' already present in TrustedHosts."
    }
  } catch {
    Write-Warning "Failed to modify TrustedHosts: $($_.Exception.Message)"
  }
}

# ---------------- ENTRY ----------------
try {
  if ($Help) {
    Show-Help
    return
  }

  Write-Headline "MAST client preparation starting"
  $prepTotalSw = [System.Diagnostics.Stopwatch]::StartNew()

  # 1) Ensure computer name
  $renamed = Ensure-ComputerName -NewName $HostName -Reboot:$Reboot

  # If rename requested with reboot, the machine will restart and the rest won't run now.
  if ($renamed -and $Reboot) {
    $prepTotalSw.Stop()
    Write-Host ('[TIMING] Total (prepare-mast-client.ps1, interrupted by reboot): {0}' -f $prepTotalSw.Elapsed.ToString('mm\:ss\.fff')) -ForegroundColor Cyan
    return
  }

  # 2) Ensure local admin user 'mast', prompting for password only if user missing
  Ensure-LocalAdminUser -UserName 'mast'

  # 3) WinRM firewall + remoting (HTTPS listener deferred — last operation after handshake line)
  Initialize-MastWinRmFirewallAndRemoting

  # 4) TrustedHosts for provider if specified
  Set-TrustedHostsIfNeeded -Provider $Provider

  # 5) Reset the Windows evaluation grace period so it does not expire during testing.
  # slmgr /rearm can stall or otherwise prevent the WinRM SOAP response from completing when this
  # script is invoked via tools/run-remote-script-winrm.py (sets env MAST_RUN_ID). Skip in that case;
  # run prepare locally on the unit if you need the rearm.
  if ([bool]$env:MAST_RUN_ID) {
    Write-Headline "Windows evaluation license (rearm skipped)"
    Write-Host "Skipping slmgr /rearm during remote WinRM run (MAST_RUN_ID set). Run locally if you need /rearm."
  } else {
    Write-Headline "Rearming Windows evaluation license"
    $rearmResult = & slmgr /rearm 2>&1
    Write-Host "slmgr /rearm: $rearmResult"
  }

  # 6) Disable Windows Update automatic installation for the duration of provisioning.
  #    Prevents mid-run reboots. Restored to download-only (AUOptions=3) after provisioning.
  Write-Headline "Suppressing Windows Update automatic installs during provisioning"
  $auPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
  New-Item -Path $auPath -Force | Out-Null
  Set-ItemProperty -Path $auPath -Name NoAutoUpdate  -Value 1 -Type DWord
  Set-ItemProperty -Path $auPath -Name AUOptions     -Value 1 -Type DWord
  Set-ItemProperty -Path $auPath -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord
  Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
  Set-Service  wuauserv -StartupType Disabled
  Write-Host "Windows Update automatic installs disabled."

  # --- Prepare phase complete: summary and timing before any WinRM HTTPS listener recreation ---
  Write-Headline "Prepare phase complete (before optional WinRM HTTPS listener)"
  Write-Host "Summary:"
  Write-Host (" - Computer name: {0}{1}" -f $HostName, $(if ($renamed -and -not $Reboot) {" (pending reboot)"} else {""}))
  Write-Host " - Local admin user: mast"
  if ($Provider) { Write-Host (" - Provider added to TrustedHosts: {0}" -f $Provider) }
  if ($renamed -and -not $Reboot) { Write-Host "`nNOTE: Reboot is required for the new computer name to take effect." -ForegroundColor Yellow }

  Write-Host ('[TIMING] Through prepare_safe_complete (before WinRM HTTPS listener): {0}' -f $prepTotalSw.Elapsed.ToString('mm\:ss\.fff')) -ForegroundColor Cyan

  # Handshake for orchestrators: appears in transcript before winrm.cmd work that may recycle WinRM.
  Emit-PrepareSafeCompleteSignal -ComputerHostName $HostName

  Install-MastWinRmHttpsListener -PrimaryHostName $HostName

  Write-Headline "Done"
  Write-Host "`nNext steps from the provider machine:"
  if (Test-MastHttpsListenerPresent) {
    Write-Host "  - Connect with: Enter-PSSession -ComputerName <client-ip> -UseSSL -Credential (Get-Credential)"
  } else {
    Write-Host "  - WinRM over HTTP (5985) is available; HTTPS listener was not created (see warnings above if any)."
  }
  Write-Host "  - Admin share: \\<client-ip>\C$  (use .\mast credentials)"

  $prepTotalSw.Stop()
  Write-Host ('[TIMING] Total (prepare-mast-client.ps1): {0}' -f $prepTotalSw.Elapsed.ToString('mm\:ss\.fff')) -ForegroundColor Cyan

} catch {
  Write-Error "Fatal: $($_.Exception.Message)"
  exit 1
}
