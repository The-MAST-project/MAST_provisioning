#requires -Version 5.1
# Read-only snapshot of a unit's OS patch state, printed as one JSON object between
# marker lines (MAST_provisioning#15). tools/fleet-drift-report.py uploads this file with
# mast-pending-reboot.ps1 and runs it; the verdict is computed server-side by
# prov.os_drift, so this script reports what it finds and judges nothing.
#
# The field set is the contract with prov.os_drift.OsProbe -- a closed model, so a field
# added here must be added there too.
[CmdletBinding()]
param()

${ErrorActionPreference} = 'Stop'
${ProgressPreference} = 'SilentlyContinue'

if (-not (Get-Command Get-MastPendingRebootReason -ErrorAction SilentlyContinue)) {
    . (Join-Path ${PSScriptRoot} 'mast-pending-reboot.ps1')
}

${PROBE_VERSION} = 1
${BEGIN_MARK} = '====MAST-OS-PATCH-PROBE-BEGIN===='
${END_MARK} = '====MAST-OS-PATCH-PROBE-END===='

# Native tools answer through exit code and stdout; a stderr line must not become a
# terminating error under 'Stop' (see CLAUDE.md on *>$null).
function Invoke-NativeLine {
    param([string]${FilePath}, [string[]]${Arguments})
    ${prev} = ${ErrorActionPreference}
    ${ErrorActionPreference} = 'Continue'
    try {
        ${out} = & ${FilePath} @Arguments 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ ExitCode = ${LASTEXITCODE}; Lines = @(${out}) }
    }
    finally {
        ${ErrorActionPreference} = ${prev}
    }
}

function Get-FileVersionToken {
    param([string]${Path})
    if (-not (Test-Path -LiteralPath ${Path})) { return $null }
    # FileVersion reads '4.8.4724.0 built by: NET48REL1LAST_C'; the first token is the version.
    return ((Get-Item -LiteralPath ${Path}).VersionInfo.FileVersion -split ' ')[0]
}

function Get-ServiceStartMode {
    param([string]${Name})
    ${svc} = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f ${Name}) -ErrorAction SilentlyContinue
    if (${svc}) { return [string]${svc}.StartMode }
    return $null
}

${cv} = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

${hotfixes} = @(Get-HotFix | ForEach-Object {
        [ordered]@{
            id           = [string]$_.HotFixID
            description  = [string]$_.Description
            installed_on = $(if ($_.InstalledOn) { $_.InstalledOn.ToString('yyyy-MM-dd') } else { $null })
        }
    })

# The LCU the unit is on, and when it went on, from the servicing store itself. Not from
# 'dism /Get-Packages': its date text follows a locale PowerShell does not report (mast00
# prints 10/06/2026 for 10 June under an en-US culture), so it cannot be parsed reliably.
${CBS_STATE_INSTALLED} = 112
${cbsPackages} = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages'
${rollup} = $null
${rollupInstalled} = $null
foreach (${key} in (Get-ChildItem -LiteralPath ${cbsPackages} | Where-Object { $_.PSChildName -like 'Package_for_RollupFix~*' })) {
    ${pkg} = Get-ItemProperty -LiteralPath ${key}.PSPath
    if (${pkg}.CurrentState -ne ${CBS_STATE_INSTALLED}) { continue }
    ${rollup} = (${key}.PSChildName -split '~')[-1]
    ${fileTime} = ([long]${pkg}.InstallTimeHigh -shl 32) -bor ([long]${pkg}.InstallTimeLow -band 0xFFFFFFFFL)
    if (${fileTime}) { ${rollupInstalled} = [datetime]::FromFileTimeUtc(${fileTime}).ToString('yyyy-MM-dd') }
}

${health} = Invoke-NativeLine -FilePath 'dism.exe' -Arguments @('/Online', '/Cleanup-Image', '/CheckHealth', '/English')
${healthText} = ${health}.Lines -join ' '
${componentStore} = 'unknown'
if (${health}.ExitCode -eq 0 -and ${healthText} -match 'No component store corruption detected') { ${componentStore} = 'healthy' }
elseif (${healthText} -match 'component store is repairable') { ${componentStore} = 'repairable' }
elseif (${healthText} -match 'cannot be repaired') { ${componentStore} = 'corrupt' }

${reagent} = Invoke-NativeLine -FilePath 'reagentc.exe' -Arguments @('/info')
${winre} = $null
foreach (${line} in ${reagent}.Lines) {
    if (${line} -match 'Windows RE status:\s*(\S+)') { ${winre} = $Matches[1] }
}

${secureBoot} = $null
try { ${secureBoot} = [bool](Confirm-SecureBootUEFI) } catch { ${secureBoot} = $null }

${netDir} = Join-Path ${env:WINDIR} 'Microsoft.NET\Framework64\v4.0.30319'
${ndp} = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue

${au} = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue
${task} = Get-ScheduledTask -TaskName 'mast-no-windows-updates' -ErrorAction SilentlyContinue

${probe} = [ordered]@{
    probe_version   = ${PROBE_VERSION}
    computer        = [string]${env:COMPUTERNAME}
    product_name    = [string]${cv}.ProductName
    edition_id      = [string]${cv}.EditionID
    current_build   = [int]${cv}.CurrentBuild
    ubr             = [int]${cv}.UBR
    rollup_package  = ${rollup}
    rollup_installed = ${rollupInstalled}
    hotfixes        = ${hotfixes}
    dotnet          = [ordered]@{
        release          = $(if (${ndp}) { [int]${ndp}.Release } else { $null })
        mscorlib_version = Get-FileVersionToken -Path (Join-Path ${netDir} 'mscorlib.dll')
    }
    pending_reboot  = Get-MastPendingRebootReason
    free_c_bytes    = [long](Get-PSDrive -Name C).Free
    component_store = ${componentStore}
    winre           = ${winre}
    secure_boot     = ${secureBoot}
    lockdown        = [ordered]@{
        no_auto_update = $(if (${au} -and $null -ne ${au}.NoAutoUpdate) { [int]${au}.NoAutoUpdate } else { $null })
        task_state     = $(if (${task}) { [string]${task}.State } else { $null })
        wuauserv       = Get-ServiceStartMode -Name 'wuauserv'
        usosvc         = Get-ServiceStartMode -Name 'UsoSvc'
        waasmedicsvc   = Get-ServiceStartMode -Name 'WaaSMedicSvc'
    }
}

Write-Output ${BEGIN_MARK}
Write-Output (ConvertTo-Json -InputObject ${probe} -Depth 5 -Compress)
Write-Output ${END_MARK}
