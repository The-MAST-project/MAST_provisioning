<#
.SYNOPSIS
  Prepare a Windows client for MAST: set name, create 'mast' admin (prompted password), and enable secure remoting.

.DESCRIPTION
  This script:
    - takes a HostName parameter and renames the computer if needed
    - creates a local user 'mast' and adds it to Administrators (prompts for password if user missing)
    - enables PowerShell Remoting (WinRM), creates a self-signed cert for HTTPS listener, opens firewall ports
    - optionally adds a provider IP/DNS to WSMan TrustedHosts
    - does NOT change network settings (DHCP remains)

.NOTES
  - Run this script AS ADMINISTRATOR on the target machine.
  - If you request a reboot after renaming (-Reboot), the machine will restart and further actions will not run until next boot.
  - This script prefers Desktop PowerShell cmdlets (Get-LocalUser / New-LocalUser); it contains fallbacks using net.exe for older OS variants.
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
    Write-Host "Computer name already '$current' — no change needed."
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

function Create-LocalUser {
  param(
    [string]$UserName,
    [System.Security.SecureString]$SecurePassword
  )
  if (Get-Command -Name New-LocalUser -ErrorAction SilentlyContinue) {
    New-LocalUser -Name $UserName `
                  -Password $SecurePassword `
                  -PasswordNeverExpires:$true `
                  -AccountNeverExpires:$true `
                  -UserMayNotChangePassword:$false -ErrorAction Stop
  } else {
    # fallback using 'net user' which requires converting secure string to plaintext temporarily
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $proc = Start-Process -FilePath net -ArgumentList "user", $UserName, $plain, "/add" -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "Failed to create local user with net user (code $($proc.ExitCode))." }
    # set account to never expires (if supported)
    Start-Process -FilePath net -ArgumentList "user", $UserName, "/expires:never" -NoNewWindow -Wait | Out-Null
  }
}

function Ensure-LocalAdminUser {
  param(
    [string]$UserName = 'mast'
  )
  Write-Headline "Ensuring local admin user '$UserName' exists"
  $user = Try-GetLocalUser -UserName $UserName
  if ($null -ne $user) {
    Write-Host "User '$UserName' already exists."
  } else {
    Write-Host "User '$UserName' not found. You will be prompted for a password to create it."
    $securePw = Read-Host -AsSecureString "Enter password for local user '$UserName' (input hidden)"
    if (-not $securePw) { throw "No password entered; aborting user creation." }
    Create-LocalUser -UserName $UserName -SecurePassword $securePw
    Write-Host "User '$UserName' created."
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

function Enable-WinRM-HttpHttps {
  Write-Headline "Enabling PowerShell Remoting (WinRM) and configuring firewall"
  try {
    Enable-PSRemoting -SkipNetworkProfileCheck -Force -ErrorAction Stop
  } catch {
    Write-Warning "Enable-PSRemoting had a problem: $($_.Exception.Message) — continuing."
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

  # Create or refresh a self-signed cert for WinRM HTTPS and create listener
  Write-Headline "Creating self-signed certificate and configuring WinRM HTTPS listener"
  try {
    $dnsNames = @($env:COMPUTERNAME)
    if ($HostName) { $dnsNames += $HostName }
    $cert = New-SelfSignedCertificate -DnsName $dnsNames -CertStoreLocation Cert:\LocalMachine\My -KeyLength 2048 -NotAfter (Get-Date).AddYears(5) -ErrorAction Stop

    # Remove existing HTTPS listeners to avoid conflicts
    try {
      Get-ChildItem WSMan:\LocalHost\Listener\ -ErrorAction SilentlyContinue | `
        Where-Object { $_.Keys -match 'Transport=HTTPS' } | ForEach-Object { Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
    } catch {}

    # Create new listener
    New-Item -Path WSMan:\LocalHost\Listener -Transport HTTPS -Address * -Hostname $dnsNames[0] -CertificateThumbprint $cert.Thumbprint -ErrorAction Stop | Out-Null
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

  # 1) Ensure computer name
  $renamed = Ensure-ComputerName -NewName $HostName -Reboot:$Reboot

  # If rename requested with reboot, the machine will restart and the rest won't run now.
  if ($renamed -and $Reboot) { return }

  # 2) Ensure local admin user 'mast', prompting for password only if user missing
  Ensure-LocalAdminUser -UserName 'mast'

  # 3) Enable WinRM + HTTPS + firewall
  Enable-WinRM-HttpHttps

  # 4) TrustedHosts for provider if specified
  Set-TrustedHostsIfNeeded -Provider $Provider

  # 5) Reset the Windows evaluation grace period so it does not expire during testing.
  Write-Headline "Rearming Windows evaluation license"
  $rearmResult = & slmgr /rearm 2>&1
  Write-Host "slmgr /rearm: $rearmResult"

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

  Write-Headline "Done"
  Write-Host "Summary:"
  Write-Host (" - Computer name: {0}{1}" -f $HostName, $(if ($renamed -and -not $Reboot) {" (pending reboot)"} else {""}))
  Write-Host " - Local admin user: mast"
  if ($Provider) { Write-Host (" - Provider added to TrustedHosts: {0}" -f $Provider) }

  Write-Host "`nNext steps from the provider machine:"
  Write-Host "  - Connect with: Enter-PSSession -ComputerName <client-ip> -UseSSL -Credential (Get-Credential)"
  Write-Host "  - Admin share: \\<client-ip>\C$  (use .\mast credentials)"
  if ($renamed -and -not $Reboot) { Write-Host "`nNOTE: Reboot is required for the new computer name to take effect." -ForegroundColor Yellow }

} catch {
  Write-Error "Fatal: $($_.Exception.Message)"
  exit 1
}
