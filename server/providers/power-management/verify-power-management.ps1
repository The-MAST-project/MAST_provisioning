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

# 5) BIOS power policy -- REPORTED, NEVER ASSERTED.
#
# The unit must power itself back on when mains returns, and that setting lives
# in BIOS setup, which provisioning cannot write (the ASUS WMI provider's
# SetOptionData is a stub on this BIOS -- see server\lib\mast-firmware.ps1).
# A check whose subject provisioning cannot own must not fail the run: the same
# rule verify-diagnostics.ps1 applies with Add-DiagWarn. Nothing below appends
# to ${fail}; a drifted BIOS is loud in the log and in the facts sidecar, and
# the unit still finishes provisioning.
function Write-PMWarn {
    param([string]${Detail})
    Write-VLog ("[WARN] bios-power-policy: {0}" -f ${Detail})
}

${firmwareLib} = Join-Path ${PSScriptRoot} 'mast-firmware.ps1'
if (-not (Test-Path ${firmwareLib})) { ${firmwareLib} = Join-Path ${PSScriptRoot} '..\..\lib\mast-firmware.ps1' }
${biosFacts} = [ordered]@{ bios_check = 'not-run' }
if (-not (Test-Path ${firmwareLib})) {
    Write-PMWarn 'mast-firmware.ps1 not found in the payload; BIOS power policy not checked.'
} else {
    try {
        . ${firmwareLib}
        ${state} = Get-MastFirmwarePolicyState -ScriptRoot ${PSScriptRoot}
        Write-VLog ("bios-power-policy: status={0} board='{1}' bios='{2}' sha256={3}" -f `
            ${state}.Status, ${state}.BaseboardProduct, ${state}.BiosVersion, ${state}.Sha256)
        foreach (${f} in @(${state}.Fields)) {
            Write-VLog ("  {0} @ {1}: actual={2} expect={3} {4}" -f `
                ${f}.Name, ${f}.Offset, ${f}.Actual, ${f}.Expect, $(if (${f}.Ok) { 'OK' } else { 'DRIFT' }))
        }
        if (${state}.Status -eq 'match') {
            Write-VLog 'bios-power-policy: matches the known-good baseline for this board.'
        } else {
            foreach (${m} in @(${state}.Messages)) { Write-PMWarn ${m} }
        }
        ${biosFacts} = [ordered]@{
            bios_check       = ${state}.Status
            bios_version     = ${state}.BiosVersion
            baseboard        = ${state}.BaseboardProduct
            setup_sha256     = ${state}.Sha256
            baseline_matched = [bool]${state}.BaselineMatched
            needs_attention  = [bool]${state}.NeedsAttention
        }
        foreach (${f} in @(${state}.Fields)) {
            ${biosFacts}[('field_' + (${f}.Name -replace '[^A-Za-z0-9]+', '_').ToLowerInvariant())] = ${f}.Actual
        }
    } catch {
        # Never let a firmware read break a verify that is otherwise green.
        Write-PMWarn ("BIOS power policy check errored (reported, not asserted): {0}" -f $_.Exception.Message)
        ${biosFacts} = [ordered]@{ bios_check = 'error'; bios_error = $_.Exception.Message }
    }
}

# Facts feed installed-manifest.json, which tools\fleet-drift-report.py already
# gathers per unit -- so a drifted or unverifiable BIOS surfaces fleet-wide
# without a second tool having to go look for it.
try {
    ${factsTable} = @{}
    foreach (${k} in ${biosFacts}.Keys) { ${factsTable}[${k}] = ${biosFacts}[${k}] }
    ${null} = Write-MastModuleFacts -Module 'power-management' -Facts ${factsTable}
}
catch { Write-VLog ("WARNING: could not write power-management facts: {0}" -f $_.Exception.Message) }

if (${fail}.Count -eq 0) {
    Set-Content -LiteralPath ${smokeFile} -Encoding UTF8 -Value 'power_management_ok'
    Write-VLog 'PASS: system sleep/hibernate disabled; NIC power management hardened where present'
    exit 0
}
else {
    Write-VLog ('FAIL: ' + (${fail} -join '; '))
    exit 1
}
