# Pester unit tests for the pure helpers in
# server/providers/instrument-profiles/instrument-link-lib.ps1.
#
# The chains are the ones surveyed on the fleet 2026-09-23 (MAST_provisioning#221).
# The PnP reads that produce them are calibrate-instruments.ps1's; only the
# verdict is tested here.
#
# Run (Pester 3.x, Windows PowerShell 5.1):
#   Invoke-Pester -Path server\tests\instrument-link-lib.Tests.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\providers\instrument-profiles\instrument-link-lib.ps1')

function New-Hop {
    param([string]$InstanceId, [string]$BusDesc)
    [pscustomobject]@{ InstanceId = $InstanceId; BusReportedDeviceDesc = $BusDesc }
}

$root30 = New-Hop 'USB\ROOT_HUB30\4&1A2B3C4D&0&0' ''
$root20 = New-Hop 'USB\ROOT_HUB20\4&5E6F7A8B&0&0' ''
$viaSs = New-Hop 'USB\VID_2109&PID_0211\5&11111111&0&1' 'USB3.0 Hub'
$viaHs = New-Hop 'USB\VID_2109&PID_2211\5&22222222&0&2' 'USB2.0 Hub'
$cypress = New-Hop 'USB\VID_04B4&PID_6572\6&33333333&0&3' 'USB2.0 Hub'

Describe 'Get-MastUsbLinkVerdict' {
    It 'passes mast02/mast03: camera on the VIA hub SuperSpeed face' {
        (Get-MastUsbLinkVerdict -Chain @($viaSs, $root30)).Verdict | Should Be 'PASS'
    }
    It 'fails mast01/mast04: camera behind the Cypress USB 2.0 hub' {
        (Get-MastUsbLinkVerdict -Chain @($cypress, $viaHs, $root30)).Verdict | Should Be 'FAIL'
    }
    It 'fails a camera on the VIA hub USB 2.0 companion even with no Cypress hub' {
        (Get-MastUsbLinkVerdict -Chain @($viaHs, $root30)).Verdict | Should Be 'FAIL'
    }
    It 'cannot verify a camera directly on an xHCI root port, which serves both speeds under one node' {
        (Get-MastUsbLinkVerdict -Chain @($root30)).Verdict | Should Be 'UNVERIFIED'
    }
    It 'fails a camera directly on a USB 2.0 root port' {
        (Get-MastUsbLinkVerdict -Chain @($root20)).Verdict | Should Be 'FAIL'
    }
    It 'judges only the immediate parent' {
        (Get-MastUsbLinkVerdict -Chain @($viaSs, $cypress, $root30)).Verdict | Should Be 'PASS'
    }
    It 'accepts a spaced or point-release SuperSpeed hub description' {
        (Get-MastUsbLinkVerdict -Chain @((New-Hop 'USB\VID_0BDA&PID_0411\1' 'USB 3.2 Hub'), $root30)).Verdict | Should Be 'PASS'
    }
    It 'fails a hub that reports no description' {
        (Get-MastUsbLinkVerdict -Chain @((New-Hop 'USB\VID_1234&PID_5678\1' ''), $root30)).Verdict | Should Be 'FAIL'
    }
    It 'fails a camera whose parent could not be read' {
        (Get-MastUsbLinkVerdict -Chain @()).Verdict | Should Be 'FAIL'
    }
    It 'names the immediate parent in the reason' {
        (Get-MastUsbLinkVerdict -Chain @($cypress, $viaHs, $root30)).Reason | Should Match 'VID_04B4&PID_6572'
    }
}

Describe 'Format-MastUsbChain' {
    It 'renders each hop as its VID/PID and description, camera-side first' {
        Format-MastUsbChain -Chain @($cypress, $viaHs, $root30) |
            Should Be 'VID_04B4&PID_6572 "USB2.0 Hub" -> VID_2109&PID_2211 "USB2.0 Hub" -> ROOT_HUB30'
    }
    It 'trims the space padding the VIA hub reports after its description' {
        Format-MastUsbChain -Chain @((New-Hop 'USB\VID_2109&PID_0211\5&1' 'USB3.0 Hub             '), $root30) |
            Should Be 'VID_2109&PID_0211 "USB3.0 Hub" -> ROOT_HUB30'
    }
}
