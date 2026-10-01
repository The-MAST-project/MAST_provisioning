#requires -Version 5.1
# The one statement of "does Windows have a reboot pending, and why". Dot-sourced by
# the reboot provider (which acts on it) and by mast-os-patch-probe.ps1 (which reports
# it), so the two cannot disagree about what counts.

function Get-MastPendingRebootReason {
    [CmdletBinding()]
    param()

    ${reasons} = New-Object System.Collections.Generic.List[string]

    # Most installers (vcredist, ASCOM) queue file replacements here when they cannot
    # overwrite a DLL in use.
    ${sm} = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    ${pfr} = Get-ItemProperty -Path ${sm} -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
    if (${pfr} -and ${pfr}.PendingFileRenameOperations) {
        [void]${reasons}.Add('PendingFileRenameOperations')
    }

    # Component Based Servicing has staged changes (an update, an optional feature)
    # that apply only across a reboot.
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        [void]${reasons}.Add('CBS RebootPending')
    }

    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        [void]${reasons}.Add('WindowsUpdate RebootRequired')
    }

    return ,${reasons}.ToArray()
}
