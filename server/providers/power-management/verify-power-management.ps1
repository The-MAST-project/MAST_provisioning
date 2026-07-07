#requires -Version 5.1
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
Set-StrictMode -Off  # mast-log.ps1 enables StrictMode; we probe optional properties

${verifyLog} = Get-MastVerifyLog -Module 'power-management'
${smokeFile} = Get-MastSmokeMarker -Module 'power-management'

function Write-VLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${verifyLog} -Encoding UTF8 `
    -Value ("[{0}] verify-power-management.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

${fail} = @()

# 1) Provider smoke marker present.
if (-not (Test-Path -LiteralPath ${smokeFile})) {
    Write-VLog ("FAIL: smoke marker missing at {0}" -f ${smokeFile})
    exit 1
}

# 2) Hibernate disabled (HibernateEnabled == 0).
${hib} = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled' -ErrorAction SilentlyContinue).HibernateEnabled
Write-VLog ("HibernateEnabled={0}" -f ${hib})
if (${hib} -ne 0) { ${fail} += 'hibernate not disabled' }

# 3) AC standby timeout == 0 (never) on the current scheme.
${q} = (& powercfg.exe /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>&1 | Out-String)
${m} = [regex]::Match(${q}, 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)')
${ac} = if (${m}.Success) { [Convert]::ToInt32(${m}.Groups[1].Value, 16) } else { -1 }
Write-VLog ("standby-timeout-ac index={0}" -f ${ac})
if (${ac} -ne 0) { ${fail} += 'standby-timeout-ac not 0 (never)' }

# 4) NIC power management + WoL on the Intel I225/I226 adapter(s), if present.
#    On the dev VM there is no such adapter, so this part is vacuous (the system
#    sleep checks above are what the VM exercises). On real unit hardware the
#    onboard NIC is checked.
${nics} = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceDescription -like 'Intel(R) Ethernet Controller*I22[56]*' })
Write-VLog ("Intel I225/I226 adapters found: {0}" -f ${nics}.Count)
foreach (${n} in ${nics}) {
    ${pm} = Get-NetAdapterPowerManagement -Name ${n}.Name -ErrorAction SilentlyContinue
    ${off} = [string]${pm}.AllowComputerToTurnOffDevice
    ${wol} = [string]${pm}.WakeOnMagicPacket
    ${ss}  = [string]${pm}.SelectiveSuspend
    Write-VLog ("  {0}: AllowComputerToTurnOffDevice={1} WakeOnMagicPacket={2} SelectiveSuspend={3}" -f ${n}.Name, ${off}, ${wol}, ${ss})
    if (${off} -ne 'Disabled') { ${fail} += ("NIC {0} AllowComputerToTurnOffDevice not Disabled" -f ${n}.Name) }
    if (${wol} -ne 'Disabled') { ${fail} += ("NIC {0} WakeOnMagicPacket not Disabled" -f ${n}.Name) }
}

if (${fail}.Count -eq 0) {
    Set-Content -LiteralPath ${smokeFile} -Encoding UTF8 -Value 'power_management_ok'
    Write-VLog 'PASS: system sleep/hibernate disabled; NIC power management hardened where present'
    exit 0
}
else {
    Write-VLog ('FAIL: ' + (${fail} -join '; '))
    exit 1
}
