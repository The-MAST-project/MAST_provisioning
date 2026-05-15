#requires -Version 5.1
# Shared utility functions for MAST client-side scripts (bootstrap, prepare, onboard).
# Dot-source this file; do not run it directly. ASCII-only.

function Disable-WindowsAutoUpdate {
    $auPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    New-Item -Path $auPath -Force | Out-Null
    Set-ItemProperty -Path $auPath -Name NoAutoUpdate                 -Value 1 -Type DWord
    Set-ItemProperty -Path $auPath -Name AUOptions                    -Value 1 -Type DWord
    Set-ItemProperty -Path $auPath -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Set-Service  wuauserv -StartupType Disabled
}
