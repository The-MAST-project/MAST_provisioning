#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]${AssetsRoot}    = ${PSScriptRoot},
    [string]${InstallerName} = 'USBPcapSetup-1.5.4.0.exe'
)

try {
    ${provLocal}  = Join-Path ${PSScriptRoot} 'provisioning.psm1'
    ${provGlobal} = 'C:\ProgramData\MAST\provisioning.psm1'
    if (Test-Path ${provLocal}) {
        Import-Module ${provLocal} -Force -ErrorAction Stop -DisableNameChecking
    }
    elseif (Test-Path ${provGlobal}) {
        Import-Module ${provGlobal} -Force -ErrorAction Stop -DisableNameChecking
    }
    else {
        throw "provisioning.psm1 not found next to script or in ${provGlobal}"
    }
}
catch {
    throw "Failed to import provisioning.psm1: $($_.Exception.Message)"
}

function Get-InstalledUsbPcapCmd {
    ${candidates} = @(
        (Join-Path ${env:ProgramFiles} 'USBPcap\USBPcapCMD.exe'),
        'C:\Program Files\USBPcap\USBPcapCMD.exe',
        'C:\Program Files (x86)\USBPcap\USBPcapCMD.exe'
    )
    foreach (${p} in ${candidates}) {
        if (Test-Path -LiteralPath ${p}) { return ${p} }
    }
    return $null
}

${log} = Start-ProvisionLog -Component 'provide-usbpcap'
try {
    # Same admin-token consideration as the npcap provider: USBPcap registers
    # a kernel driver and needs BUILTIN\Administrators in the effective token.
    # WinRM network logons often filter that group out; log up front so a
    # missing-service failure later points clearly here.
    ${id}    = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    ${princ} = New-Object System.Security.Principal.WindowsPrincipal(${id})
    Write-Host ("ELEVATION user={0} isAdmin={1} authType={2} (driver install needs isAdmin=True)" `
        -f ${id}.Name,
           ${princ}.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator),
           ${id}.AuthenticationType)

    ${existing} = Get-InstalledUsbPcapCmd
    if (${existing}) {
        Write-Host ("USBPcap already present at {0}; nothing to do." -f ${existing})
        exit 0
    }

    ${installerPath} = Join-Path ${AssetsRoot} ${InstallerName}
    if (-not (Test-Path ${installerPath})) {
        throw "USBPcap installer not found: ${installerPath}"
    }

    # Pre-trust the USBPcap installer's Authenticode publisher so the kernel
    # driver install does not block on a Session-0 "trust this publisher?"
    # prompt that nothing can dismiss. See provide-npcap.ps1 for the full
    # rationale -- same mechanism, same trade-off.
    Write-Host "Extracting Authenticode publisher cert from USBPcap installer for TrustedPublisher pre-trust..."
    try {
        ${sig} = Get-AuthenticodeSignature -FilePath ${installerPath} -ErrorAction Stop
        if ($null -eq ${sig}.SignerCertificate) {
            Write-Host "[WARN] USBPcap installer has no Authenticode signer; driver-trust prompt may still hang the install."
        } else {
            ${signer} = ${sig}.SignerCertificate
            Write-Host ("Publisher: {0} (thumbprint {1})" -f ${signer}.Subject, ${signer}.Thumbprint)
            ${store} = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher', 'LocalMachine')
            ${store}.Open('ReadWrite')
            try { ${store}.Add(${signer}) } finally { ${store}.Close() }
            Write-Host "Added USBPcap publisher to LocalMachine\TrustedPublisher."
        }
    } catch {
        Write-Host ("[WARN] Could not pre-trust USBPcap publisher: {0}" -f $_.Exception.Message)
    }

    # USBPcap installer is NSIS-based. /S is silent. The installer drops a
    # kernel driver and registers a service for it -- both require an
    # unfiltered admin token. Under WinRM the calling user has a filtered
    # NTLM token (BUILTIN\Admins stripped from effective groups); in run #9
    # the install reported success but `sc create USBPcap` silently no-op'd,
    # leaving the verify to fail with "service not registered". Run via
    # SYSTEM scheduled task instead so the install has full driver-install
    # rights. A reboot may still be requested (exit 3010); we accept that.
    Write-Host ("Installing USBPcap from {0} as SYSTEM (scheduled task)..." -f ${installerPath})
    ${rc} = Invoke-ExeAsSystem -Executable ${installerPath} -Arguments '/S' `
        -TimeoutMinutes 10 -TaskNamePrefix 'MAST-USBPcapInstall'
    if (${rc} -ne 0 -and ${rc} -ne 3010) {
        throw ("USBPcap installer exited with code {0}" -f ${rc})
    }

    Start-Sleep -Seconds 3
    ${exe} = Get-InstalledUsbPcapCmd
    if (-not ${exe}) {
        throw ("USBPcapCMD.exe not found after install (installer exit {0})." -f ${rc})
    }

    # Confirm the kernel driver service registered. If the installer left the
    # service in Manual that is fine; Wireshark starts it on demand.
    ${svc} = Get-Service -Name 'USBPcap' -ErrorAction SilentlyContinue
    if ($null -eq ${svc}) {
        Write-Host "[WARN] USBPcap service not registered; capture will not work until a reboot or manual sc create."
    } else {
        Write-Host ("USBPcap service: status={0} starttype={1}" -f ${svc}.Status, ${svc}.StartType)
    }

    Write-Host ("USBPcap installed at {0}" -f ${exe})
}
finally {
    Stop-ProvisionLog
}
exit 0
