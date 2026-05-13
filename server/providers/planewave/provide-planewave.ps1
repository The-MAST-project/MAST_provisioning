param(
    [string]${AssetsRoot} = "."
)

${ErrorActionPreference} = "Stop"
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "planewave-install.log"
${innoLog} = Join-Path ${logDir} "pwi4-inno-setup.log"

function Write-MastPwLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

# Always create the log file (Write-Host does not pipe to Tee-Object in Windows PowerShell 5.1;
# silent Inno may emit no stdout so Tee-Object would never open the file.)
Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] PlaneWave provide-planewave.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    Write-MastPwLog "Starting PlaneWave installation..."

    # Install PWI4 (Inno Setup 6.x per vendor log -- use Inno silent flags, not NSIS /S.)
    ${pwi4InstallerPath} = Join-Path ${AssetsRoot} "Setup_PWI_4.1.8_Final.exe"
    if (-not (Test-Path ${pwi4InstallerPath})) {
        throw "PWI4 installer not found at ${pwi4InstallerPath}"
    }

    Write-MastPwLog "Launching PWI4 setup (silent Inno + dedicated Inno log)."
    ${argList} = @(
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/SP-',
        ('/LOG="{0}"' -f ${innoLog})
    )
    ${p} = Start-Process -FilePath ${pwi4InstallerPath} -ArgumentList ${argList} -PassThru -Wait -NoNewWindow
    try { ${p}.Refresh() } catch {}
    Write-MastPwLog ("Setup_PWI_4.1.8_Final.exe exit code: {0}" -f ${p}.ExitCode)
    if ($null -ne ${p}.ExitCode -and ${p}.ExitCode -ne 0) {
        throw ("PWI4 installer exited with code {0}. See Inno log: {1}" -f ${p}.ExitCode, ${innoLog})
    }
    Start-Sleep -Seconds 5

    # Locate pwi4.exe - search default Program Files trees (vendor path may vary).
    ${pwi4ExePath} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
        -Recurse -Filter 'pwi4.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not ${pwi4ExePath}) {
        throw "pwi4.exe not found after installation"
    }
    Write-MastPwLog ("Found pwi4.exe at: {0}" -f ${pwi4ExePath})

    # Register PWI4 as an NSSM service so it is running before MAST_unit starts.
    # PWI4 is a GUI app; SERVICE_INTERACTIVE_PROCESS allows it to initialise in
    # session 0 on headless units (same pattern used for PHD2).
    ${nssmExe} = 'C:\Program Files\nssm\nssm.exe'
    if (Test-Path -LiteralPath ${nssmExe}) {
        ${pwi4SvcName} = 'PWI4'
        ${existingPwi4Svc} = Get-Service -Name ${pwi4SvcName} -ErrorAction SilentlyContinue
        if ($null -eq ${existingPwi4Svc}) {
            Write-MastPwLog "Registering PWI4 as NSSM service..."
            & ${nssmExe} install ${pwi4SvcName} ${pwi4ExePath}
            & ${nssmExe} set ${pwi4SvcName} Start SERVICE_AUTO_START
            & ${nssmExe} set ${pwi4SvcName} Type SERVICE_INTERACTIVE_PROCESS
            & ${nssmExe} set ${pwi4SvcName} AppStdout 'C:\MAST\logs\pwi4_stdout.log'
            & ${nssmExe} set ${pwi4SvcName} AppStderr 'C:\MAST\logs\pwi4_stderr.log'
            & ${nssmExe} set ${pwi4SvcName} AppRotateFiles 1
            & ${nssmExe} set ${pwi4SvcName} AppRotateBytes 10485760
            Start-Service -Name ${pwi4SvcName} -ErrorAction SilentlyContinue
            Write-MastPwLog "PWI4 service registered and started."
        } else {
            Write-MastPwLog "PWI4 service already registered -- skipping."
        }
    } else {
        Write-MastPwLog "NSSM not found; skipping PWI4 service registration."
    }

    # Extract PS3 CLI tools
    ${ps3cliZipPath} = Join-Path ${AssetsRoot} "ps3cli.zip"
    if (-not (Test-Path ${ps3cliZipPath})) {
        throw "PS3 CLI archive not found at ${ps3cliZipPath}"
    }

    ${ps3cliDestPath} = "C:\Users\mast\Documents\PlaneWave\ps3cli"
    New-Item -ItemType Directory -Path ${ps3cliDestPath} -Force | Out-Null

    Write-MastPwLog ("Extracting PS3 CLI tools to {0}" -f ${ps3cliDestPath})
    ${zipOut} = Expand-Archive -Path ${ps3cliZipPath} -DestinationPath ${ps3cliDestPath} -Force 2>&1 | Out-String
    if (${zipOut}) { Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${zipOut} }

    # Verify PS3 CLI extraction
    if (-not (Test-Path ${ps3cliDestPath})) {
        throw "PS3 CLI directory not created after extraction at ${ps3cliDestPath}"
    }

    Write-MastPwLog "PlaneWave installation completed successfully"
    exit 0
}
catch {
    ${errorMsg} = "PlaneWave installation failed: $_"
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
