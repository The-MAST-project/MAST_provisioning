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
    ${pwi4InstallerPath} = Join-Path ${AssetsRoot} "Setup_PWI_4.1.6_Final.exe"
    if (-not (Test-Path ${pwi4InstallerPath})) {
        throw "PWI4 installer not found at ${pwi4InstallerPath}"
    }

    # Idempotent re-run guard: skip the Inno installer if PWI4 is already present.
    # Re-running it over an existing install (PWI4 is kept running by the NSSM
    # service registered below) blocks on an "application is running / already
    # installed" modal the silent flags do not suppress; in Session 0 there is no
    # desktop to dismiss it, and Start-Process -Wait has no timeout, so the run
    # would hang forever. pwi4.exe presence is the authoritative success criterion.
    ${pwi4ExePath} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
        -Recurse -Filter 'pwi4.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (${pwi4ExePath}) {
        Write-MastPwLog ("PWI4 already installed at {0}; skipping installer (idempotent re-run)." -f ${pwi4ExePath})
    } else {
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
        Write-MastPwLog ("Setup_PWI_4.1.6_Final.exe exit code: {0}" -f ${p}.ExitCode)
        Start-Sleep -Seconds 5
        ${pwi4ExePath} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
            -Recurse -Filter 'pwi4.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
        # A non-zero installer exit is not fatal if pwi4.exe is present.
        if ($null -ne ${p}.ExitCode -and ${p}.ExitCode -ne 0) {
            if (${pwi4ExePath}) {
                Write-MastPwLog ("[WARN] PWI4 installer exit {0} but pwi4.exe present; treating as installed. See Inno log: {1}" -f ${p}.ExitCode, ${innoLog})
            } else {
                throw ("PWI4 installer exited with code {0} and pwi4.exe is absent. See Inno log: {1}" -f ${p}.ExitCode, ${innoLog})
            }
        }
        if (-not ${pwi4ExePath}) {
            throw "pwi4.exe not found after installation"
        }
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

    # Install PWShutter (idempotent re-run guard, same rationale as PWI4 above).
    ${pwShutterInstallerPath} = Join-Path ${AssetsRoot} "Setup_PWShutter_1.15.0.exe"
    if (-not (Test-Path ${pwShutterInstallerPath})) {
        throw "PWShutter installer not found at ${pwShutterInstallerPath}"
    }
    ${pwShutterExePath} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
        -Recurse -Filter 'PWShutter.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (${pwShutterExePath}) {
        Write-MastPwLog ("PWShutter already installed at {0}; skipping installer (idempotent re-run)." -f ${pwShutterExePath})
    } else {
        Write-MastPwLog "Launching PWShutter setup (silent install)."
        ${argListShutter} = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-')
        ${pShutter} = Start-Process -FilePath ${pwShutterInstallerPath} -ArgumentList ${argListShutter} -PassThru -Wait -NoNewWindow
        try { ${pShutter}.Refresh() } catch {}
        Write-MastPwLog ("Setup_PWShutter_1.15.0.exe exit code: {0}" -f ${pShutter}.ExitCode)
        Start-Sleep -Seconds 3
        ${pwShutterExePath} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
            -Recurse -Filter 'PWShutter.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
        if ($null -ne ${pShutter}.ExitCode -and ${pShutter}.ExitCode -ne 0 -and -not ${pwShutterExePath}) {
            throw ("PWShutter installer exited with code {0} and PWShutter.exe is absent" -f ${pShutter}.ExitCode)
        }
    }

    # Register PWShutter.exe as an NSSM service (same pattern as PWI4).
    # SERVICE_INTERACTIVE_PROCESS lets the GUI run in session 0 on headless units.
    if (-not ${pwShutterExePath}) {
        Write-Warning "PWShutter.exe not found after installation; skipping service registration."
    } elseif (Test-Path -LiteralPath ${nssmExe}) {
        ${pwShutterSvcName} = 'PWShutter'
        ${existingPwShutterSvc} = Get-Service -Name ${pwShutterSvcName} -ErrorAction SilentlyContinue
        if ($null -eq ${existingPwShutterSvc}) {
            Write-MastPwLog ("Registering PWShutter as NSSM service at {0}" -f ${pwShutterExePath})
            & ${nssmExe} install ${pwShutterSvcName} ${pwShutterExePath}
            & ${nssmExe} set ${pwShutterSvcName} Start SERVICE_AUTO_START
            & ${nssmExe} set ${pwShutterSvcName} Type SERVICE_INTERACTIVE_PROCESS
            & ${nssmExe} set ${pwShutterSvcName} AppStdout 'C:\MAST\logs\pwshutter_stdout.log'
            & ${nssmExe} set ${pwShutterSvcName} AppStderr 'C:\MAST\logs\pwshutter_stderr.log'
            & ${nssmExe} set ${pwShutterSvcName} AppRotateFiles 1
            & ${nssmExe} set ${pwShutterSvcName} AppRotateBytes 10485760
            Start-Service -Name ${pwShutterSvcName} -ErrorAction SilentlyContinue
            Write-MastPwLog "PWShutter service registered and started."
        } else {
            Write-MastPwLog "PWShutter service already registered -- skipping."
        }
    } else {
        Write-MastPwLog "NSSM not found; skipping PWShutter service registration."
    }

    # Extract PS3 CLI tools
    ${ps3cliZipPath} = Join-Path ${AssetsRoot} "ps3cli.zip"
    if (-not (Test-Path ${ps3cliZipPath})) {
        throw "PS3 CLI archive not found at ${ps3cliZipPath}"
    }

    ${ps3cliDestPath} = "C:\Users\mast\Documents\PlaneWave\ps3cli"
    # Clear any prior extraction first: the build folder name is dated
    # (e.g. ps3cli-2024-09-10), so Expand-Archive -Force does NOT overwrite an
    # older build's folder -- it would linger beside the new one and the older
    # on-demand ps3cli.exe could be picked up instead of the special --server build.
    if (Test-Path -LiteralPath ${ps3cliDestPath}) {
        Write-MastPwLog ("Removing prior PS3 CLI extraction at {0}" -f ${ps3cliDestPath})
        Remove-Item -LiteralPath ${ps3cliDestPath} -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path ${ps3cliDestPath} -Force | Out-Null

    Write-MastPwLog ("Extracting PS3 CLI tools to {0}" -f ${ps3cliDestPath})
    ${zipOut} = Expand-Archive -Path ${ps3cliZipPath} -DestinationPath ${ps3cliDestPath} -Force 2>&1 | Out-String
    if (${zipOut}) { Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${zipOut} }

    # Verify PS3 CLI extraction
    if (-not (Test-Path ${ps3cliDestPath})) {
        throw "PS3 CLI directory not created after extraction at ${ps3cliDestPath}"
    }

    # --- Mock PlateSolve3 star catalog (UC4/Orca) so 'ps3cli --server' will boot ---
    # ps3cli is used by MAST_unit ONLY for autofocus analysis (begin_analyze_focus on
    # port 8998), NOT for plate solving. But 'ps3cli --server' validates a star catalog
    # at startup and exits (code 2, "Catalog files not found") if it is absent. The real
    # UCAC4/Orca catalog is many GB and we do not need it for focus analysis, so we mock
    # just the minimum file set the startup validation checks for. Determined empirically
    # against ps3cli-2024-09-10: it requires UC4\Index.UC4 to exist and the three
    # Orca\*.orc files to exist AND be non-empty; the 180 Z###.UC4 zone files are only
    # read during an actual solve, so they are intentionally omitted.
    #
    # These exact filenames are hardcoded in this ps3cli build; if the ps3cli.zip asset
    # is ever updated, re-derive them (extract UTF-16LE strings from ps3cli.exe).
    ${ps3CatalogPath} = "C:\Users\mast\Documents\Kepler"
    ${ps3Uc4Dir}      = Join-Path ${ps3CatalogPath} 'UC4'
    ${ps3OrcaDir}     = Join-Path ${ps3CatalogPath} 'Orca'
    Write-MastPwLog ("Creating mock PlateSolve3 catalog at {0}" -f ${ps3CatalogPath})
    New-Item -ItemType Directory -Path ${ps3Uc4Dir}  -Force | Out-Null
    New-Item -ItemType Directory -Path ${ps3OrcaDir} -Force | Out-Null
    ${ps3MockBanner} = "MAST MOCK PlateSolve3 catalog file - placeholder to satisfy ps3cli --server bootup validation. NOT real catalog data. ps3cli is used only for autofocus analysis, not plate solving."
    ${ps3MockBytes}  = [System.Text.Encoding]::ASCII.GetBytes(${ps3MockBanner})
    [System.IO.File]::WriteAllBytes((Join-Path ${ps3Uc4Dir} 'Index.UC4'), ${ps3MockBytes})
    foreach (${orcaName} in @('Orca0025.orc', 'StarOrca0025.orc', 'DistOrca0025.orc')) {
        [System.IO.File]::WriteAllBytes((Join-Path ${ps3OrcaDir} ${orcaName}), ${ps3MockBytes})
    }

    # The mast-unit service runs as LocalSystem (NSSM install with no ObjectName), so the
    # app's Path.home()-based discovery resolves to the system profile, NOT C:\Users\mast,
    # and would find neither ps3cli.exe nor the catalog. app.py checks PS3CLI_DIR and
    # PS3CLI_CATALOG first, so set them at Machine scope (account-independent; the service
    # picks them up on its next start / the provisioning reboot).
    [Environment]::SetEnvironmentVariable('PS3CLI_DIR', ${ps3cliDestPath}, 'Machine')
    [Environment]::SetEnvironmentVariable('PS3CLI_CATALOG', ${ps3CatalogPath}, 'Machine')
    Write-MastPwLog ("Set Machine env PS3CLI_DIR={0} PS3CLI_CATALOG={1}" -f ${ps3cliDestPath}, ${ps3CatalogPath})

    Write-MastPwLog "PlaneWave installation completed successfully"
    exit 0
}
catch {
    ${errorMsg} = "PlaneWave installation failed: $_"
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
