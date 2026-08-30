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

function Import-MastPublisherCert {
    # Pre-trust a driver publisher so Windows installs its catalog-signed driver
    # without the "Would you like to install this device software?" consent
    # dialog. Mirrors provide-zwo.ps1 / provide-stage.ps1 / provide-usbpcap.ps1.
    #
    # Without this, the dialog is the whole failure: with a desktop it blocks the
    # run until someone clicks, and in Session 0 -- where provisioning normally
    # runs -- there is no desktop to show it, so the driver install fails while
    # the installer still exits 0 and the module reports success. mast04 carries
    # PWI4 and a planewave_ok smoke marker with no PlaneWave or Texas Instruments
    # driver in its store, which is what that looks like afterwards.
    param([Parameter(Mandatory)][string]${Path}, [Parameter(Mandatory)][string]${Label})
    if (-not (Test-Path -LiteralPath ${Path})) {
        throw ("{0} publisher cert not found at {1}" -f ${Label}, ${Path})
    }
    ${cert} = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
    ${cert}.Import(${Path})
    ${store} = New-Object System.Security.Cryptography.X509Certificates.X509Store(
        [System.Security.Cryptography.X509Certificates.StoreName]::TrustedPublisher,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
    )
    ${store}.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try { ${store}.Add(${cert}) } finally { ${store}.Close() }
    Write-MastPwLog ("Trusted {0} publisher: {1} (thumbprint {2})" -f ${Label}, ${cert}.Subject, ${cert}.Thumbprint)
}

# Always create the log file (Write-Host does not pipe to Tee-Object in Windows PowerShell 5.1;
# silent Inno may emit no stdout so Tee-Object would never open the file.)
Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] PlaneWave provide-planewave.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    Write-MastPwLog "Starting PlaneWave installation..."

    # BEFORE the installer, and unconditionally: PWI4 bundles catalog-signed USB
    # drivers for the L-mount and for the TI Stellaris/Tiva electronics behind
    # the PlaneWave accessories, and both prompt for consent unless their
    # publisher is already trusted.
    Import-MastPublisherCert -Path (Join-Path ${AssetsRoot} 'planewave-driver-publisher.cer') -Label 'PlaneWave'
    Import-MastPublisherCert -Path (Join-Path ${AssetsRoot} 'ti-tiva-driver-publisher.cer') -Label 'Texas Instruments (Tiva/Stellaris)'

    # Install PWI4 (Inno Setup 6.x per vendor log -- use Inno silent flags, not NSIS /S.)
    ${pwi4InstallerPath} = Join-Path ${AssetsRoot} "Setup_PWI_4.1.6_Final.exe"
    if (-not (Test-Path ${pwi4InstallerPath})) {
        throw "PWI4 installer not found at ${pwi4InstallerPath}"
    }

    # Idempotent re-run guard: skip the Inno installer if PWI4 is already present.
    # Re-running it over an existing install (PWI4 may be running -- the unit
    # raises it itself) blocks on an "application is running / already
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
        try { ${p}.Refresh() } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
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

    # Stage the bundled USB drivers into the driver store, OUTSIDE the idempotent
    # installer guard above. This is the half that repairs a unit already
    # carrying PWI4: the guard skips the installer on a re-run, so trusting the
    # publisher alone would never install anything on mast01-mast04. Same shape
    # and same reason as provide-zwo.ps1.
    #
    # /add-driver without /install: no PlaneWave hardware is attached during
    # provisioning, so the aim is only to have the driver ready in the store for
    # when a device is plugged in.
    #
    # The win2k\ variants next to these are legacy and deliberately not staged;
    # these three are what Windows itself selected on mast05.
    ${pwRoot} = Split-Path -Parent ${pwi4ExePath}
    ${driverInfs} = @(
        (Join-Path ${pwRoot} 'LMountDriver\usb_dev_cserial.inf'),
        (Join-Path ${pwRoot} 'StellarisDrivers\usb_dev_serial.inf'),
        (Join-Path ${pwRoot} 'StellarisDrivers\boot_usb.inf')
    )
    ${staged} = 0
    foreach (${inf} in ${driverInfs}) {
        if (-not (Test-Path -LiteralPath ${inf})) {
            Write-MastPwLog ("[WARN] bundled driver not found, skipping: {0}" -f ${inf})
            continue
        }
        ${pnpOut} = & pnputil.exe /add-driver ${inf} 2>&1
        foreach (${line} in @(${pnpOut})) { Write-MastPwLog ("[pnputil] {0}" -f ${line}) }
        if (${LASTEXITCODE} -eq 0) { ${staged}++ }
        else { Write-MastPwLog ("[WARN] pnputil /add-driver exited {0} for {1}" -f ${LASTEXITCODE}, ${inf}) }
    }
    if (${staged} -eq 0) {
        throw ("No PlaneWave USB driver could be staged from {0}. The bundled driver layout has changed; update the inf list in this provider." -f ${pwRoot})
    }

    # Assert the outcome rather than the absence of an error (#62): the store
    # itself has to name both publishers, which is exactly the check mast04
    # would fail today.
    ${providers} = & pnputil.exe /enum-drivers 2>$null | Select-String -Pattern 'Provider Name'
    foreach (${want} in 'Planewave', 'Texas Instruments') {
        if (${providers} -match ${want}) {
            Write-MastPwLog ("Driver store carries a '{0}' driver." -f ${want})
        } else {
            throw ("Staged {0} driver package(s) but the driver store reports no '{1}' provider." -f ${staged}, ${want})
        }
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
        try { ${pShutter}.Refresh() } catch { Write-Verbose "ignored: $($_.Exception.Message)" }
        Write-MastPwLog ("Setup_PWShutter_1.15.0.exe exit code: {0}" -f ${pShutter}.ExitCode)
        Start-Sleep -Seconds 3
        ${pwShutterExePath} = Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' `
            -Recurse -Filter 'PWShutter.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
        if ($null -ne ${pShutter}.ExitCode -and ${pShutter}.ExitCode -ne 0 -and -not ${pwShutterExePath}) {
            throw ("PWShutter installer exited with code {0} and PWShutter.exe is absent" -f ${pShutter}.ExitCode)
        }
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

    # --- PlaneWave PWTools (portable utility bundle) --------------------------
    # PWTools is a portable .NET app (PWTools.exe + DLLs) the vendor ships as a
    # dated zip (top-level PWTools-YYYY-MM-DD/). No installer -- extract beside
    # ps3cli under the mast operator's PlaneWave folder and the operator runs
    # PWTools.exe. Clear any prior (dated) extraction first so re-provision does
    # not leave stale copies alongside the new one.
    ${pwToolsZip} = Join-Path ${AssetsRoot} 'PWTools-2024-09-17.zip'
    if (-not (Test-Path -LiteralPath ${pwToolsZip})) {
        throw "PWTools archive not found at ${pwToolsZip}"
    }
    ${pwToolsDest} = "C:\Users\mast\Documents\PlaneWave\PWTools"
    if (Test-Path -LiteralPath ${pwToolsDest}) {
        Write-MastPwLog ("Removing prior PWTools extraction at {0}" -f ${pwToolsDest})
        Remove-Item -LiteralPath ${pwToolsDest} -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path ${pwToolsDest} -Force | Out-Null
    Write-MastPwLog ("Extracting PWTools to {0}" -f ${pwToolsDest})
    ${pwToolsOut} = Expand-Archive -Path ${pwToolsZip} -DestinationPath ${pwToolsDest} -Force 2>&1 | Out-String
    if (${pwToolsOut}) { Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${pwToolsOut} }
    ${pwToolsExe} = Get-ChildItem -Path ${pwToolsDest} -Recurse -Filter 'PWTools.exe' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not ${pwToolsExe}) {
        throw ("PWTools.exe not found under {0} after extraction" -f ${pwToolsDest})
    }
    Write-MastPwLog ("PWTools ready at {0}" -f ${pwToolsExe})

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
    # PS3CLI_CATALOG there, so discovery does not depend on whose home directory
    # the unit process happens to have.
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

    # app.py falls back to Path.home()-based discovery for ps3cli.exe and the catalog,
    # which ties the answer to whichever account raises the unit. It checks PS3CLI_DIR and
    # PS3CLI_CATALOG first, so set both at Machine scope: account-independent, and so the
    # answer stays the same for the operator's interactive session today and for whatever
    # raises the unit later (#82). A process picks them up on its next start, or at the
    # provisioning reboot.
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
