param(
    [string]${AssetsRoot}  = ".",
    # Match mastw: D: is a persistent file-backed mount, not a ramdisk. The
    # image file itself is supplied out-of-band per compare-mastw/GAPS.md
    # action items; we register the scheduled task either way so the mount
    # works on the next reboot after the image lands.
    # Filename tracks the upstream-shipped image (see The-MAST-project/MAST_provisioning
    # commit "added TBD for pre-populated image file"). If the canonical image
    # changes, update this default and any out-of-band staging instructions together.
    [string]${ImagePath}   = 'C:\MAST\Shared\MAST-15GB-indexes-5202+5203.img',
    [string]${TaskName}    = 'MAST-ImDisk-Persistent'
)

${ErrorActionPreference} = "Stop"
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "imdisk-install.log"

function Write-ImDiskLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-imdisk.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    ${zipPath} = Join-Path ${AssetsRoot} "ImDiskTk-x64.zip"
    if (-not (Test-Path ${zipPath})) {
        throw "ImDisk archive not found at ${zipPath}"
    }

    ${extractDir} = Join-Path ${env:TEMP} "imdisk-install"
    New-Item -ItemType Directory -Path ${extractDir} -Force | Out-Null

    Write-ImDiskLog ("Extracting ImDisk archive to {0}" -f ${extractDir})
    Expand-Archive -Path ${zipPath} -DestinationPath ${extractDir} -Force
    Write-ImDiskLog "Extraction complete."

    ${subfolders} = @(Get-ChildItem -Path ${extractDir} -Directory | Where-Object { $_.Name -like "ImDiskTk*" })
    if (${subfolders}.Count -eq 0) {
        throw "ImDiskTk subfolder not found in extracted archive"
    }
    ${installDir} = ${subfolders}[0].FullName
    Write-ImDiskLog ("Found ImDisk folder: {0}" -f ${subfolders}[0].Name)

    ${installBat} = Join-Path ${installDir} "install.bat"
    if (-not (Test-Path ${installBat})) {
        throw ("install.bat not found at {0}" -f ${installBat})
    }

    Write-ImDiskLog ("Running install.bat /silent from {0}" -f ${installDir})
    ${batOut} = & cmd.exe /c ("`"{0}`" /silent" -f ${installBat}) 2>&1
    if (${batOut}) {
        foreach (${line} in ${batOut}) {
            Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[bat] {0}" -f ${line})
        }
    }
    Write-ImDiskLog ("install.bat exit code: {0}" -f ${LASTEXITCODE})
    if (${LASTEXITCODE} -ne 0) {
        Write-ImDiskLog ("WARNING: install.bat exited with code {0}" -f ${LASTEXITCODE})
    }

    ${imdiskExe} = "C:\Windows\System32\imdisk.exe"
    if (-not (Test-Path ${imdiskExe})) {
        throw ("ImDisk executable not found at {0}" -f ${imdiskExe})
    }
    Write-ImDiskLog ("ImDisk found at: {0}" -f ${imdiskExe})

    # install.bat unconditionally drops three shortcuts on the current user's
    # desktop (and sometimes the Public desktop, depending on ImDiskTk
    # version). There is no documented flag to suppress them. Clean them up
    # so operator desktops are not cluttered with tools no human needs to
    # invoke directly -- we drive ImDisk via the scheduled task only.
    ${shortcutNames} = @(
        'ImDisk Virtual Disk Driver.lnk',
        'Mount Image File.lnk',
        'RamDisk Configuration.lnk'
    )
    ${desktopDirs} = @(
        (Join-Path ${env:USERPROFILE} 'Desktop'),
        (Join-Path ${env:PUBLIC} 'Desktop'),
        'C:\Users\Public\Desktop'
    ) | Sort-Object -Unique
    foreach (${dd} in ${desktopDirs}) {
        if (-not (Test-Path -LiteralPath ${dd})) { continue }
        foreach (${sn} in ${shortcutNames}) {
            ${lnk} = Join-Path ${dd} ${sn}
            if (Test-Path -LiteralPath ${lnk}) {
                Remove-Item -LiteralPath ${lnk} -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath ${lnk})) {
                    Write-ImDiskLog ("Removed desktop shortcut: {0}" -f ${lnk})
                }
            }
        }
    }

    ${imageDir} = Split-Path -Parent ${ImagePath}
    if (-not (Test-Path -LiteralPath ${imageDir})) {
        New-Item -ItemType Directory -Path ${imageDir} -Force | Out-Null
        Write-ImDiskLog ("Created image directory: {0}" -f ${imageDir})
    }
    if (-not (Test-Path -LiteralPath ${ImagePath})) {
        Write-ImDiskLog ("[WARN] Image file not present yet: {0}. Task will be registered; mount will succeed on first reboot after the image is placed." -f ${ImagePath})
    } else {
        Write-ImDiskLog ("Image file present: {0}" -f ${ImagePath})
    }

    Write-ImDiskLog "Creating boot-time file-backed mount scheduled task..."
    ${argLine} = ('-a -m D: -f "{0}"' -f ${ImagePath})
    ${taskAction} = New-ScheduledTaskAction -Execute ${imdiskExe} -Argument ${argLine}
    ${taskTrigger} = New-ScheduledTaskTrigger -AtStartup
    ${taskPrincipal} = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    # Clean up the previous-generation ramdisk task if it exists (Phase 1 VMs
    # had MAST-ImDisk-Ramdisk; the persistent mount supersedes it).
    foreach (${legacy} in @('MAST-ImDisk-Ramdisk')) {
        if (Get-ScheduledTask -TaskName ${legacy} -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName ${legacy} -ErrorAction SilentlyContinue -Confirm:$false
            Write-ImDiskLog ("Removed legacy scheduled task: {0}" -f ${legacy})
        }
    }

    Unregister-ScheduledTask -TaskName ${TaskName} -ErrorAction SilentlyContinue -Confirm:$false
    Register-ScheduledTask -TaskName ${TaskName} `
        -Description ("Mount D: from {0} on system startup (ImDisk file-backed)" -f ${ImagePath}) `
        -Action ${taskAction} `
        -Trigger ${taskTrigger} `
        -Principal ${taskPrincipal} `
        -ErrorAction Stop | Out-Null
    Write-ImDiskLog ("Scheduled task created: {0}" -f ${TaskName})

    # Mount D: immediately if (a) the image is present and (b) D: is not
    # already in use. This means provisioning steps that run later in the
    # same session (e.g. astrometry's smoke solve, which needs the index
    # files on D:\mast-indexes) do not have to wait for a reboot. The
    # scheduled task above still re-establishes the mount on every boot,
    # so the immediate mount and the persistent mount stay consistent.
    if (-not (Test-Path -LiteralPath ${ImagePath})) {
        Write-ImDiskLog ("[INFO] Skipping immediate mount: image not present at {0}. Boot task will pick it up later." -f ${ImagePath})
    } elseif (Test-Path -LiteralPath 'D:\') {
        Write-ImDiskLog "[INFO] D: already in use; skipping immediate mount. Existing mount left intact."
    } else {
        Write-ImDiskLog ("Mounting D: from {0} via ImDisk (immediate) ..." -f ${ImagePath})
        ${mountArgs} = @('-a', '-m', 'D:', '-f', ${ImagePath})
        ${mp} = Start-Process -FilePath ${imdiskExe} -ArgumentList ${mountArgs} `
            -PassThru -Wait -WindowStyle Hidden
        try { ${mp}.Refresh() } catch {}
        ${mountExit} = ${mp}.ExitCode
        if ($null -eq ${mountExit}) {
            throw "imdisk -a -m D: did not report an exit code (treating as failure)."
        }
        if (${mountExit} -ne 0) {
            throw ("imdisk -a -m D: exited {0}. Boot-time task is still registered, but the immediate mount failed." -f ${mountExit})
        }
        # Confirm the mount actually surfaced as a drive. ImDisk can return 0 even
        # if the mount silently misbehaved, so probe the drive root explicitly.
        ${tries} = 0
        while ((-not (Test-Path -LiteralPath 'D:\')) -and (${tries} -lt 10)) {
            Start-Sleep -Milliseconds 200
            ${tries}++
        }
        if (-not (Test-Path -LiteralPath 'D:\')) {
            throw "imdisk reported success but D:\ is not visible after 2s. Check imdisk service state."
        }
        Write-ImDiskLog "D: mounted successfully (immediate)."
    }

    Remove-Item -Path ${extractDir} -Recurse -Force -ErrorAction SilentlyContinue

    Write-ImDiskLog "ImDisk installation completed successfully."
    exit 0
}
catch {
    ${errorMsg} = ("ImDisk installation failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
