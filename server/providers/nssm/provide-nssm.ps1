#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]${AssetsRoot} = ${PSScriptRoot},
    [string]${ZipPath},                                   # Optional explicit path to the nssm-*.zip
    [string]${InstallDir} = 'C:\Program Files\nssm',      # Final install location (added to PATH)
    # Copy even if the installed nssm.exe already matches the archive's.
    [switch]${Force}
)

# --- Import shared helpers ---
try {
    ${provLocal}  = Join-Path ${PSScriptRoot} 'provisioning.psm1'
    ${provGlobal} = 'C:\ProgramData\MAST\provisioning.psm1'

    if (Test-Path ${provLocal}) {
        Import-Module ${provLocal} -Force -ErrorAction Stop -DisableNameChecking
    }
    elseif (Test-Path ${provGlobal}) {
        Import-Module ${provGlobal} -Force -ErrorAction Stop -DisableNameChecking
    }
    else {
        throw "provisioning.psm1 not found next to script or in ${provGlobal}"
    }
}
catch {
    throw "Failed to import provisioning.psm1: $($_.Exception.Message)"
}

try {
    if (-not ${ZipPath}) {
        ${ZipPath} = Get-ChildItem -Path ${AssetsRoot} -Filter 'nssm-*.zip' |
            Select-Object -First 1 -ExpandProperty FullName
        if (-not ${ZipPath}) {
            throw "No nssm-*.zip found in ${AssetsRoot}"
        }
    }
    if (-not (Test-Path ${ZipPath})) {
        throw "NSSM archive not found: ${ZipPath}"
    }

    # --- Expand to temporary staging folder ---
    ${stage} = Join-Path ${env:TEMP} ("nssm_stage_{0:yyyyMMdd_HHmmss}" -f (Get-Date))
    Confirm-Dir ${stage}
    Expand-AnyArchive -ArchivePath ${ZipPath} -Destination ${stage}

    # --- Locate nssm.exe ---
    ${rootDir} = Get-ChildItem -Path ${stage} -Directory -Filter 'nssm-*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not ${rootDir}) { ${rootDir} = Get-Item ${stage} }

    ${archFolder} = 'win32'
    if ([Environment]::Is64BitOperatingSystem) { ${archFolder} = 'win64' }

    ${candDir} = Join-Path ${rootDir}.FullName ${archFolder}
    ${exe}     = Join-Path ${candDir} 'nssm.exe'
    if (-not (Test-Path ${exe})) {
        ${found} = Get-ChildItem -Path ${stage} -Recurse -Filter 'nssm.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (${found}) { ${exe} = ${found}.FullName }
    }
    if (-not (Test-Path ${exe})) {
        throw "Could not locate nssm.exe in expanded archive."
    }

    # --- Install NSSM ---
    # An nssm.exe already there is kept only when it IS the archive's: a unit carrying
    # an earlier vendored version must get the new one.
    ${destExe} = Join-Path ${InstallDir} 'nssm.exe'
    ${wantHash} = (Get-FileHash -LiteralPath ${exe} -Algorithm SHA256).Hash
    if (-not ${Force} -and (Test-Path -LiteralPath ${destExe}) -and
        (Get-FileHash -LiteralPath ${destExe} -Algorithm SHA256).Hash -eq ${wantHash}) {
        Add-ToSystemPath -Dir ${InstallDir}
        Write-Host "NSSM at ${InstallDir} already matches the archive; skipping. Use -Force to reinstall."
        exit 0
    }
    Confirm-Dir ${InstallDir}
    Copy-Item -Force ${exe} ${destExe}

    Add-ToSystemPath -Dir ${InstallDir}

    # --- Verify installation ---
    try {
        ${verLine} = & ${destExe} 2>&1 | Select-Object -First 1
        ${verLog}  = Join-Path (Get-MastVerifyDir) 'nssm-verify.log'
        ${verLine} | Out-File -FilePath ${verLog} -Encoding UTF8
        Write-Host "NSSM installed: ${verLine}"
    }
    catch {
        Write-Warning "NSSM executed but version check failed: $($_.Exception.Message)"
    }

    Write-Host "NSSM ready at ${InstallDir} and added to PATH."
}
finally {
    Stop-ProvisionLog
}
exit 0
