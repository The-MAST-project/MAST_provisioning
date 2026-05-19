param(
    [string]${FlagPath} = (Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'state\reboot-requested.flag')
)

# Detector-only module. Runs last in the provisioning order. If Windows reports
# a pending reboot (file rename queue, CBS, or Windows Update), drop a marker
# file the orchestrator can act on after all providers have finished. The
# orchestrator (execute-mast-provisioning.ps1) is responsible for actually
# rebooting; this module always exits 0 so it cannot fail a run.

${ErrorActionPreference} = "Stop"

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}

${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "reboot-detect.log"

function Write-RebootLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-reboot.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

${reasons} = New-Object System.Collections.Generic.List[string]

try {
    # 1. PendingFileRenameOperations: most installers (vcredist, ASCOM) queue
    #    file replacements here when they cannot overwrite a DLL in use.
    ${sm} = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    ${pfr} = Get-ItemProperty -Path ${sm} -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
    if (${pfr} -and ${pfr}.PendingFileRenameOperations) {
        [void]${reasons}.Add('PendingFileRenameOperations')
    }

    # 2. Component Based Servicing: signals when servicing stack has staged
    #    changes that need a reboot before they apply (e.g. optional features).
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        [void]${reasons}.Add('CBS RebootPending')
    }

    # 3. Windows Update auto-update marker.
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        [void]${reasons}.Add('WindowsUpdate RebootRequired')
    }

    if (${reasons}.Count -gt 0) {
        ${reasonText} = (${reasons} -join '; ')
        Write-RebootLog ("Reboot required: {0}" -f ${reasonText})

        ${flagDir} = Split-Path -Parent ${FlagPath}
        New-Item -ItemType Directory -Path ${flagDir} -Force | Out-Null
        ${payload} = ("requested_at={0}`r`nreasons={1}`r`n" -f (Get-Date -Format 'o'), ${reasonText})
        Set-Content -LiteralPath ${FlagPath} -Encoding ASCII -Value ${payload}
        Write-RebootLog ("Wrote reboot flag: {0}" -f ${FlagPath})
    } else {
        Write-RebootLog "No pending reboot detected; flag not written."
        if (Test-Path ${FlagPath}) {
            # Stale flag from a previous run -- the system already rebooted, so
            # clear it so the orchestrator does not loop.
            Remove-Item -LiteralPath ${FlagPath} -Force -ErrorAction SilentlyContinue
            Write-RebootLog ("Cleared stale flag: {0}" -f ${FlagPath})
        }
    }

    ${smokeDir} = Get-MastSmokeDir
    New-Item -ItemType Directory -Path ${smokeDir} -Force | Out-Null
    Set-Content -LiteralPath (Join-Path ${smokeDir} 'reboot-smoke.txt') -Encoding UTF8 -Value 'reboot_detector_ok'

    exit 0
}
catch {
    # Never fail the run from this detector. Log and exit 0.
    ${errorMsg} = ("Reboot detector swallowed error: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 0
}
