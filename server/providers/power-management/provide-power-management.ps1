#requires -Version 5.1
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}

${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} 'power-management-install.log'

function Write-PMLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 `
    -Value ("[{0}] provide-power-management.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# The unit NIC is the onboard Intel I225-V; match I225/I226 so a board revision
# does not silently skip the fix. No match on the dev VM (emulated NIC) -- the
# NIC step is then skipped and only the system sleep settings apply.
${nicPattern} = 'Intel(R) Ethernet Controller*I22[56]*'

try {
    Write-PMLog 'Disabling system sleep, standby and hibernate (powercfg)...'
    # The unit must stay reachable for remote operation -- never sleep on AC/DC.
    & powercfg.exe /change standby-timeout-ac 0 | Out-Null
    & powercfg.exe /change standby-timeout-dc 0 | Out-Null
    & powercfg.exe /change hibernate-timeout-ac 0 | Out-Null
    & powercfg.exe /change hibernate-timeout-dc 0 | Out-Null
    & powercfg.exe /hibernate off | Out-Null
    Write-PMLog '  standby/hibernate timeouts set to 0 (never); hibernate disabled.'

    ${nics} = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -like ${nicPattern} })
    if (${nics}.Count -eq 0) {
        Write-PMLog ("WARNING: no Intel I225/I226 adapter found (pattern '{0}'); NIC power-management step skipped. Expected on the dev VM (emulated NIC); on real unit hardware this means the onboard NIC was not detected." -f ${nicPattern})
    }
    foreach (${n} in ${nics}) {
        Write-PMLog ("Hardening NIC power management: {0} ({1})" -f ${n}.Name, ${n}.InterfaceDescription)
        # "Allow the computer to turn off this device to save power" -> off.
        Set-NetAdapterPowerManagement -Name ${n}.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
        # PCIe selective-suspend -> off (best effort; not all adapters expose it).
        Set-NetAdapterPowerManagement -Name ${n}.Name -SelectiveSuspend Disabled -ErrorAction SilentlyContinue
        # The unit is power-cycled via the DLI switch + BIOS S0, never woken by
        # magic packets -- disable WoL so stray traffic cannot wake it.
        Set-NetAdapterPowerManagement -Name ${n}.Name -WakeOnMagicPacket Disabled -WakeOnPattern Disabled -ErrorAction SilentlyContinue
        Write-PMLog '  AllowComputerToTurnOffDevice=Disabled, SelectiveSuspend=Disabled, WakeOnMagicPacket/Pattern=Disabled'
    }

    ${smoke} = Get-MastSmokeMarker -Module 'power-management'
    New-Item -ItemType Directory -Path (Split-Path -Parent ${smoke}) -Force | Out-Null
    Set-Content -LiteralPath ${smoke} -Encoding UTF8 -Value ("nic_count={0}" -f ${nics}.Count)
    Write-PMLog 'power-management completed successfully'
    exit 0
}
catch {
    ${msg} = "power-management failed: $_"
    Write-Host ${msg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${msg}
    exit 1
}
