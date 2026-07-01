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
        ${pwi4SvcName} = 'mast-pwi4'
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
        ${pwShutterSvcName} = 'mast-pwshutter'
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

    # --- Real PlaneWave PlateSolve3 star catalog (UCAC4/Orca) ------------------
    # 'ps3cli --server' validates a PlateSolve3 catalog at startup and exits
    # ("Catalog files not found") if it is absent. We ship the real vendor
    # catalog (PlaneWave "PlateSolve 3 Catalog", parts 1+2), which supports both
    # autofocus analysis and real plate solving. It is a two-file Inno Setup
    # payload that must be staged together (the .bin sits beside the .exe with
    # this exact name):
    #   Setup_PlateSolve3_Catalog.exe   (~324 KB installer stub)
    #   Setup_PlateSolve3_Catalog-1.bin (~1.9 GB catalog data)
    # These are too large to keep in the repo, so -- like the astrometry index
    # seed -- they are build-host-local (C:\MAST\ps3-catalog) and build-mast.ps1
    # stages them into the payload beside this script (see the planewave block in
    # build-mast.ps1). The installer lays down ~3.6 GB: UC4\{Index.UC4,
    # Z000..Z179.UC4}, UC4Mag14\..., and Orca\{Orca,StarOrca,DistOrca}####.orc.
    #
    # It installs to {userdocs}\Kepler by default; we pin /DIR so the location is
    # deterministic regardless of which account runs provisioning, and point
    # PS3CLI_CATALOG there (the mast-unit service runs as LocalSystem, so its
    # home-based lookup would otherwise miss it).
    ${ps3CatalogPath}      = "C:\Users\mast\Documents\Kepler"
    ${ps3CatalogInstaller} = Join-Path ${AssetsRoot} "Setup_PlateSolve3_Catalog.exe"
    ${ps3CatalogData}      = Join-Path ${AssetsRoot} "Setup_PlateSolve3_Catalog-1.bin"
    ${ps3IndexFile}        = Join-Path ${ps3CatalogPath} 'UC4\Index.UC4'
    ${ps3LastZone}         = Join-Path ${ps3CatalogPath} 'UC4\Z179.UC4'
    ${ps3MinUc4Zones}      = 180   # Z000..Z179
    ${ps3MinOrcaFiles}     = 39    # 13 each of Orca / StarOrca / DistOrca

    if ((Test-Path -LiteralPath ${ps3IndexFile}) -and (Test-Path -LiteralPath ${ps3LastZone})) {
        Write-MastPwLog ("PlateSolve3 catalog already present at {0}; skipping installer (idempotent re-run)." -f ${ps3CatalogPath})
    } else {
        if (-not (Test-Path -LiteralPath ${ps3CatalogInstaller})) {
            throw ("PlateSolve3 catalog installer not found at {0}. build-mast.ps1 must stage it from C:\MAST\ps3-catalog on the build host." -f ${ps3CatalogInstaller})
        }
        if (-not (Test-Path -LiteralPath ${ps3CatalogData})) {
            throw ("PlateSolve3 catalog data not found at {0} (Setup_PlateSolve3_Catalog-1.bin must sit beside the installer with this exact name)." -f ${ps3CatalogData})
        }
        ${ps3InnoLog} = Join-Path ${logDir} "ps3-catalog-inno.log"
        Write-MastPwLog ("Installing real PlateSolve3 catalog to {0} (Inno silent; ~3.6 GB, several minutes)." -f ${ps3CatalogPath})
        ${ps3Args} = @(
            '/VERYSILENT',
            '/SUPPRESSMSGBOXES',
            '/NORESTART',
            '/SP-',
            ('/DIR="{0}"' -f ${ps3CatalogPath}),
            ('/LOG="{0}"' -f ${ps3InnoLog})
        )
        # The Inno SetupLdr bootstrapper returns BEFORE the extracted child setup
        # finishes copying (observed exit code 1 while the install completed
        # successfully in the background), so its exit code is NOT a reliable
        # success signal and -Wait returns early. Launch it, then poll until the
        # catalog is fully materialised: the last zone file exists, the expected
        # file counts are met, and no *.tmp remains under the catalog dir. File
        # presence is the authoritative success criterion (same approach as the
        # pwi4.exe install above).
        Start-Process -FilePath ${ps3CatalogInstaller} -ArgumentList ${ps3Args} -NoNewWindow | Out-Null
        ${ps3Deadline} = (Get-Date).AddMinutes(20)
        ${ps3Complete} = $false
        while ((Get-Date) -lt ${ps3Deadline}) {
            Start-Sleep -Seconds 10
            if (-not (Test-Path -LiteralPath ${ps3LastZone})) { continue }
            ${ps3Tmp} = @(Get-ChildItem -LiteralPath ${ps3CatalogPath} -Recurse -Filter '*.tmp' -File -ErrorAction SilentlyContinue)
            if (${ps3Tmp}.Count -ne 0) { continue }
            ${ps3ZoneNow} = @(Get-ChildItem -LiteralPath (Join-Path ${ps3CatalogPath} 'UC4')  -Filter 'Z*.UC4' -File -ErrorAction SilentlyContinue).Count
            ${ps3OrcaNow} = @(Get-ChildItem -LiteralPath (Join-Path ${ps3CatalogPath} 'Orca') -Filter '*.orc'  -File -ErrorAction SilentlyContinue).Count
            if (${ps3ZoneNow} -ge ${ps3MinUc4Zones} -and ${ps3OrcaNow} -ge ${ps3MinOrcaFiles}) { ${ps3Complete} = $true; break }
        }
        if (-not ${ps3Complete}) {
            throw ("PlateSolve3 catalog install did not complete within 20 min (see Inno log: {0})." -f ${ps3InnoLog})
        }
        Write-MastPwLog "PlateSolve3 catalog install completed."
    }

    # Sanity-check the installed catalog before trusting it.
    ${ps3Uc4Count}  = @(Get-ChildItem -LiteralPath (Join-Path ${ps3CatalogPath} 'UC4')  -Filter 'Z*.UC4' -File -ErrorAction SilentlyContinue).Count
    ${ps3OrcaCount} = @(Get-ChildItem -LiteralPath (Join-Path ${ps3CatalogPath} 'Orca') -Filter '*.orc'  -File -ErrorAction SilentlyContinue).Count
    Write-MastPwLog ("PlateSolve3 catalog: {0} UC4 zone files, {1} Orca files at {2}" -f ${ps3Uc4Count}, ${ps3OrcaCount}, ${ps3CatalogPath})
    if (${ps3Uc4Count} -lt ${ps3MinUc4Zones} -or ${ps3OrcaCount} -lt ${ps3MinOrcaFiles}) {
        throw ("PlateSolve3 catalog incomplete (UC4 zones={0} expected>={1}, Orca={2} expected>={3})." -f ${ps3Uc4Count}, ${ps3MinUc4Zones}, ${ps3OrcaCount}, ${ps3MinOrcaFiles})
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
