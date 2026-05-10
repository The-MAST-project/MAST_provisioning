param(
    [string]$UnitHost = "mast01",
    [string]$ProvIP   = "192.168.64.10",
    [string]$HostName = "mast01",
    [string]$User     = ".\mast",
    [string]$Password = "physics",
    [string]$MastPass = "physics"
)

$pass  = ConvertTo-SecureString $Password -AsPlainText -Force
$cred  = New-Object System.Management.Automation.PSCredential($User, $pass)
$sopts = New-PSSessionOption -SkipCACheck -SkipCNCheck

Write-Host "Connecting to $UnitHost..."
$s = New-PSSession -ComputerName $UnitHost -Port 5985 -Credential $cred -SessionOption $sopts
if (-not $s) { Write-Error "Failed to open PSSession"; exit 1 }
Write-Host "Connected."

Invoke-Command -Session $s -ScriptBlock { Set-ExecutionPolicy Bypass -Scope Process -Force }

# 1. mast user
Write-Host "Ensuring mast user..."
Invoke-Command -Session $s -ArgumentList $MastPass -ScriptBlock {
    param($pw)
    $secpw = ConvertTo-SecureString $pw -AsPlainText -Force
    if (-not (Get-LocalUser -Name "mast" -ErrorAction SilentlyContinue)) {
        New-LocalUser -Name "mast" -Password $secpw -PasswordNeverExpires $true
        Write-Host "  Created mast user."
    } else {
        Write-Host "  mast user already exists."
    }
    $inAdmin = Get-LocalGroupMember -Group "Administrators" | Where-Object { $_.Name -match "\\mast$" }
    if (-not $inAdmin) {
        Add-LocalGroupMember -Group "Administrators" -Member "mast"
        Write-Host "  Added mast to Administrators."
    } else {
        Write-Host "  mast already in Administrators."
    }
}

# 2. Hostname
Write-Host "Setting hostname..."
Invoke-Command -Session $s -ArgumentList $HostName -ScriptBlock {
    param($hn)
    if ($env:COMPUTERNAME -ieq $hn) {
        Write-Host "  Hostname already $hn."
    } else {
        Rename-Computer -NewName $hn -Force
        Write-Host "  Renamed to $hn. Reboot required."
    }
}

# 3. TrustedHosts
Write-Host "Setting TrustedHosts..."
Invoke-Command -Session $s -ArgumentList $ProvIP -ScriptBlock {
    param($prov)
    $path = "WSMan:\localhost\Client\TrustedHosts"
    $val  = (Get-Item $path).Value
    if ($val -match [regex]::Escape($prov)) {
        Write-Host "  $prov already trusted."
    } else {
        $new = if ($val) { "$val,$prov" } else { $prov }
        Set-Item $path -Value $new -Force
        Write-Host "  Added $prov to TrustedHosts."
    }
}

# 4. LocalAccountTokenFilterPolicy
Write-Host "Setting LocalAccountTokenFilterPolicy..."
Invoke-Command -Session $s -ScriptBlock {
    $rp = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    Set-ItemProperty -Path $rp -Name "LocalAccountTokenFilterPolicy" -Value 1 -Type DWord -Force
    Write-Host "  Done."
}

Remove-PSSession $s
Write-Host "Preparation complete."
