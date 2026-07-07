$ErrorActionPreference = 'Continue'

Write-Host "=== MAST: recover WinRM + HTTPS listener ===" -ForegroundColor Cyan

function Step($msg) {
  Write-Host ""
  Write-Host ("--- " + $msg) -ForegroundColor Cyan
}

Step "Force network profiles to Private (WinRM/WSMan requirement)"
try {
  Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
  Get-NetConnectionProfile | Format-Table Name, InterfaceAlias, NetworkCategory -AutoSize
} catch {
  Write-Host ("WARN: could not set network profile: " + $_.Exception.Message)
}

Step "Ensure WinRM service is running"
try {
  & sc.exe start WinRM 2>&1 | ForEach-Object { $_ }
} catch {
  Write-Host ("WARN: sc.exe start WinRM failed: " + $_.Exception.Message)
}
try {
  Get-Service WinRM | Format-Table Status, StartType, Name -AutoSize
} catch {}

Step "Quickconfig (rebuild default HTTP listener + firewall)"
try {
  & winrm.cmd quickconfig -quiet -force 2>&1 | ForEach-Object { $_ }
} catch {
  Write-Host ("WARN: winrm quickconfig failed: " + $_.Exception.Message)
}

Step "Enable Basic + AllowUnencrypted (bootstrap transport)"
try {
  Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true -Force
  Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true -Force
  New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null
  Restart-Service WinRM
  & winrm.cmd get winrm/config/service 2>&1 | Select-String 'AllowUnencrypted'
  & winrm.cmd get winrm/config/service/auth 2>&1 | Select-String 'Basic'
} catch {
  Write-Host ("WARN: could not set WSMan service knobs: " + $_.Exception.Message)
}

Step "Open firewall for WinRM HTTPS (5986)"
try {
  $ruleName = 'MAST - WinRM port 5986'
  if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5986 -Profile Any | Out-Null
  } else {
    Set-NetFirewallRule -DisplayName $ruleName -Enabled True | Out-Null
  }
} catch {
  Write-Host ("WARN: firewall rule failed: " + $_.Exception.Message)
}

Step "Create HTTPS listener using existing cert (no new cert generation)"
$cert = $null
$activeName = $env:COMPUTERNAME
try {
  $activeName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
} catch {}
try {
  $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    if (-not $_.HasPrivateKey) { return $false }
    foreach ($u in $_.DnsNameList.Unicode) {
      if ($u -eq $activeName) { return $true }
      try {
        [void][System.Net.IPAddress]::Parse($u)
        return $true
      } catch {}
    }
    return $false
  } | Sort-Object NotAfter -Descending | Select-Object -First 1
} catch {}

if (-not $cert) {
  Write-Host "ERROR: no suitable cert found for this machine name or IPv4 in Cert:\LocalMachine\My" -ForegroundColor Red
} else {
  Write-Host ("Using cert thumbprint: " + $cert.Thumbprint)
  Write-Host ("Using listener Hostname: " + $activeName)
  # WSMan provider New-Item can hang; use winrm.cmd create instead.
  try {
    # Best-effort: delete existing HTTPS listeners (ignore failures)
    & winrm.cmd delete winrm/config/Listener?Address=*+Transport=HTTPS 2>$null | Out-Null
  } catch {}

  try {
    # winrm.cmd expects: @{KEY="VALUE";KEY="VALUE"}
    $createArg = "@{Hostname=`"$activeName`";CertificateThumbprint=`"$($cert.Thumbprint)`"}"
    & winrm.cmd create winrm/config/Listener?Address=*+Transport=HTTPS $createArg 2>&1 | ForEach-Object { $_ }
  } catch {
    Write-Host ("ERROR: failed to create HTTPS listener: " + $_.Exception.Message) -ForegroundColor Red
  }
}

Step "Show listeners + service status"
try { & winrm.cmd enumerate winrm/config/listener } catch {}
try { Get-Service WinRM | Format-Table Status, StartType -AutoSize } catch {}

Write-Host ""
Write-Host "Done. If the hostname rename is pending, reboot later to apply it." -ForegroundColor Green

