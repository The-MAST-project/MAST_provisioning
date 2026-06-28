#requires -Version 5.1
[CmdletBinding()]
param(
    [string]${AssetsRoot} = "."
)

${ErrorActionPreference} = 'Stop'

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}

${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} 'intel-nic-driver-install.log'

function Write-INLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 `
    -Value ("[{0}] provide-intel-nic-driver.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    # Stage the Intel I225-V (Foxville, e2f) driver into the driver store. The
    # catalog is WHQL-signed (Microsoft Windows Hardware Compatibility Publisher),
    # so no TrustedPublisher pre-trust is needed -- pnputil stages it silently.
    #
    # /add-driver only (no /install): a fresh unit enumerates the onboard I225-V
    # and Windows picks the newest matching driver in the store, so new units come
    # up on this version. We deliberately do NOT /install: that would force-update
    # the live, already-bound NIC and reset it mid-run, dropping the provisioning
    # link. Upgrading an already-deployed unit's bound NIC is a separate, attended
    # step (pnputil /add-driver e2f.inf /install, then reconnect). The .inf/.sys/
    # .cat/.dll are flattened into AssetsRoot by build-mast.ps1.
    ${inf} = Join-Path ${AssetsRoot} 'e2f.inf'
    if (-not (Test-Path ${inf})) {
        throw "Intel I225-V driver .inf not found at ${inf}"
    }

    Write-INLog ("Staging Intel I225-V driver via PnPUtil: {0}" -f ${inf})
    ${pnpLog} = Join-Path ${logDir} 'intel-nic-pnputil.log'
    ${pnp} = Start-Process -FilePath 'pnputil.exe' `
        -ArgumentList '/add-driver', ("`"{0}`"" -f ${inf}) `
        -PassThru -WindowStyle Hidden -Wait `
        -RedirectStandardOutput ${pnpLog}
    if (Test-Path ${pnpLog}) {
        Get-Content -LiteralPath ${pnpLog} -ErrorAction SilentlyContinue |
            ForEach-Object { Write-INLog ("  pnputil: {0}" -f $_) }
    }
    Write-INLog ("PnPUtil exit code: {0}" -f ${pnp}.ExitCode)
    # 0 = added, 259 (ERROR_NO_MORE_ITEMS) = already staged.
    if ($null -ne ${pnp}.ExitCode -and ${pnp}.ExitCode -ne 0 -and ${pnp}.ExitCode -ne 259) {
        throw ("PnPUtil failed with exit code {0}" -f ${pnp}.ExitCode)
    }

    ${smoke} = Get-MastSmokeMarker -Module 'intel-nic-driver'
    New-Item -ItemType Directory -Path (Split-Path -Parent ${smoke}) -Force | Out-Null
    Set-Content -LiteralPath ${smoke} -Encoding UTF8 -Value 'intel_nic_driver_staged'
    Write-INLog 'intel-nic-driver completed successfully'
    exit 0
}
catch {
    ${msg} = "intel-nic-driver failed: $_"
    Write-Host ${msg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${msg}
    exit 1
}
