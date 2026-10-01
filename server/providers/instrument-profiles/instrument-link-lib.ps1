#requires -Version 5.1
# Guide-camera USB link verdict for calibrate-instruments.ps1 (MAST_provisioning#221).
#
# A ZWO camera behind a USB 2.0 hub reads out 6.5x slower than on SuperSpeed
# and otherwise works normally, so nothing notices. The verdict is taken from the
# PnP parent chain rather than the ZWO SDK's IsUSB3Host because the SDK has to
# open the camera, which PHD2 or the unit service may be holding.
#
# Only the immediate parent is judged: a SuperSpeed hub port only exists on a
# SuperSpeed upstream path, and a USB 2.0 parent caps the link whatever sits
# above it. PASS needs a hub whose bus-reported description names USB 3.x; a hub
# exposes its SuperSpeed and USB 2.0 faces as separate devices, so the parent
# says which one the camera took. An xHCI root hub is ONE node for both speeds,
# so a camera directly on one is UNVERIFIED. An unreadable parent FAILs.
#
# This file DEFINES FUNCTIONS ONLY -- dot-sourcing it has no side effects. The
# PnP reads live in the caller; server\tests\instrument-link-lib.Tests.ps1 covers
# these without a unit.

${script:MastUsbDualSpeedRootPattern} = '^USB\\ROOT_HUB3\d'
${script:MastUsbSuperSpeedHubPattern} = '\bUSB ?3(\.\d)? Hub\b'

function Get-MastUsbHopLabel {
    param([Parameter(Mandatory)]${Hop})
    ${segment} = (${Hop}.InstanceId -split '\\')[1]
    if (${Hop}.BusReportedDeviceDesc) { return ('{0} "{1}"' -f ${segment}, ${Hop}.BusReportedDeviceDesc.Trim()) }
    return ${segment}
}

function Format-MastUsbChain {
    param([AllowEmptyCollection()][object[]]${Chain} = @())
    return ((${Chain} | ForEach-Object { Get-MastUsbHopLabel -Hop $_ }) -join ' -> ')
}

function Get-MastUsbLinkVerdict {
    param([AllowEmptyCollection()][object[]]${Chain} = @())
    if (${Chain}.Count -eq 0) {
        return [pscustomobject]@{ Verdict = 'FAIL'; Reason = 'no USB parent readable' }
    }
    ${parent} = ${Chain}[0]
    ${label} = Get-MastUsbHopLabel -Hop ${parent}
    if (${parent}.InstanceId -match ${script:MastUsbDualSpeedRootPattern}) {
        return [pscustomobject]@{ Verdict = 'UNVERIFIED'; Reason = ('on a USB 3 root port, which serves both speeds; the PnP tree cannot tell which ({0})' -f ${label}) }
    }
    if (${parent}.BusReportedDeviceDesc -match ${script:MastUsbSuperSpeedHubPattern}) {
        return [pscustomobject]@{ Verdict = 'PASS'; Reason = ('on a SuperSpeed hub port ({0})' -f ${label}) }
    }
    return [pscustomobject]@{ Verdict = 'FAIL'; Reason = ('parent is not SuperSpeed ({0})' -f ${label}) }
}
