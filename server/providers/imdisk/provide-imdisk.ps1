param(
    [string]${AssetsRoot}  = ".",
    # D: is a VOLATILE, RAM-backed ImDisk mount (`imdisk -t vm`). The backing
    # image is a SPARSE NTFS image: 32 GB of logical space, but only the
    # actually-written index files (~10 GB) are allocated on the host disk. The
    # image is BUILT on the unit from the staged index seed (see -IndexSeedDir)
    # the first time this provider runs (the build mounts the image FILE-backed
    # to write the seed into it); on subsequent runs the existing image is
    # reused as-is.
    #
    # At RUNTIME the image is mounted with `-t vm`, so its contents are loaded
    # into RAM at attach time: the index seed is present every boot (fast
    # solving, served from RAM), while runtime writes -- temp files, acquisition
    # scratch, intermediate results -- live only in the volatile RAM overlay and
    # are WIPED on reboot. The 32 GB logical size gives runtime working room in
    # that overlay; it also means the mount commits ~32 GB of RAM (units have
    # ~64 GB), so size the image to the RAM budget. The backing .img file is
    # only ever read at mount, never written, so it stays sparse and pristine.
    #
    # NOTE: an earlier revision (2026-06-18) dropped the `-t vm` flag when it
    # switched to the self-built sparse image, which silently made D: file-backed
    # and PERSISTENT -- runtime scratch then accumulated inside the index image
    # across reboots. See the 2026-06-23 DECISIONS entry. Do not remove `-t vm`
    # from the runtime mounts.
    [string]${ImagePath}    = 'C:\MAST\Shared\MAST-32GB-indexes-5202+5203.img',
    # Logical size of the sparse virtual disk. Passed verbatim to imdisk -s and
    # used to size the sparse backing file. Keep the 'G' suffix form imdisk
    # accepts (e.g. '32G').
    [string]${DiskSize}     = '32G',
    [long]  ${DiskSizeBytes} = 34359738368,   # 32 * 1024^3, must match ${DiskSize}
    # Directory under the staged payload holding the index FITS files (the
    # "seed"). build-mast.ps1 stages C:\MAST\mast-indexes -> <payload>\mast-indexes.
    [string]${IndexSeedDir} = '',
    # Subdirectory created inside the image that astrometry.cfg points at
    # (add_path /cygdrive/d/mast-indexes).
    [string]${IndexSubdir}  = 'mast-indexes',
    [string]${TaskName}     = 'MAST-ImDisk-Persistent'
)

${ErrorActionPreference} = "Stop"
if ([string]::IsNullOrWhiteSpace(${IndexSeedDir})) {
    ${IndexSeedDir} = Join-Path ${AssetsRoot} 'mast-indexes'
}

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

# ---------------------------------------------------------------------------
# Sparse-image build helpers.
#
# ImDisk does NOT create sparse backing files (a freshly-created -s 32G image
# is fully allocated at 32 GB on disk). We therefore create the backing file
# ourselves as a sparse file BEFORE mounting it, then let ImDisk mount the
# existing 32 GB file. A QUICK NTFS format + robocopy of the ~10 GB of index
# files only writes the populated regions, so the file stays sparse (~10 GB
# allocated of 32 GB logical) -- exactly the mast02 reference layout.
# ---------------------------------------------------------------------------
function Get-FreeDriveLetter {
    # Walk Z: down to E: (C:/D: are spoken for) and return the first letter no
    # device owns, for a temporary build/seed mount. Test-Path is NOT enough
    # here: a medialess device (empty DVD drive, card reader) has no drive root
    # to Test-Path, yet its letter is taken -- imdisk then attaches the unit but
    # the letter keeps resolving to that device, format fails, and the detach
    # errors "Not an ImDisk device" (seen with a VirtualBox DVD drive at Y:).
    # DriveInfo enumerates every assigned letter regardless of media presence.
    ${used} = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
    foreach (${ch} in [char[]]([char]'Z'..[char]'E')) {
        if (${used} -notcontains ([string]${ch})) { return ([string]${ch}) }
    }
    throw "No free drive letter available for the scratch build mount."
}

function New-SparseBackingFile {
    param([Parameter(Mandatory)][string]${Path},
          [Parameter(Mandatory)][long]${Bytes})
    ${dir} = Split-Path -Parent ${Path}
    if (-not (Test-Path -LiteralPath ${dir})) {
        New-Item -ItemType Directory -Path ${dir} -Force | Out-Null
    }
    if (Test-Path -LiteralPath ${Path}) { Remove-Item -LiteralPath ${Path} -Force }
    # Create the (empty) file, mark it sparse, THEN extend to the full logical
    # size. With the sparse attribute set first, the extension is a zero range
    # and consumes no allocation.
    ${fs} = [System.IO.File]::Create(${Path}); ${fs}.Close()
    & fsutil sparse setflag "${Path}" | Out-Null
    if (${LASTEXITCODE} -ne 0) { throw ("fsutil sparse setflag failed ({0}) on {1}" -f ${LASTEXITCODE}, ${Path}) }
    ${fs} = [System.IO.File]::Open(${Path}, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite)
    try { ${fs}.SetLength(${Bytes}) } finally { ${fs}.Close() }
}

function Wait-ForDriveRoot {
    param([Parameter(Mandatory)][string]${Root}, [int]${TimeoutMs} = 5000, [switch]${Gone})
    ${tries} = 0
    ${maxTries} = [int](${TimeoutMs} / 200)
    while (${tries} -lt ${maxTries}) {
        ${present} = Test-Path -LiteralPath ${Root}
        if ((${Gone} -and -not ${present}) -or (-not ${Gone} -and ${present})) { return $true }
        Start-Sleep -Milliseconds 200
        ${tries}++
    }
    return $false
}

function Build-SparseIndexImage {
    param([Parameter(Mandatory)][string]${ImagePath},
          [Parameter(Mandatory)][string]${SeedDir},
          [Parameter(Mandatory)][long]${SizeBytes},
          [Parameter(Mandatory)][string]${SizeArg},
          [Parameter(Mandatory)][string]${ImdiskExe},
          [Parameter(Mandatory)][string]${IndexSubdir})

    if (-not (Test-Path -LiteralPath ${SeedDir})) {
        throw ("Index seed directory not found at {0}. build-mast must stage C:\MAST\mast-indexes into the payload." -f ${SeedDir})
    }
    ${seedFiles} = @(Get-ChildItem -LiteralPath ${SeedDir} -File -Recurse -ErrorAction SilentlyContinue)
    if (${seedFiles}.Count -eq 0) {
        throw ("Index seed directory {0} is empty; nothing to seed the image with." -f ${SeedDir})
    }
    ${seedGb} = ((${seedFiles} | Measure-Object Length -Sum).Sum / 1GB)
    Write-ImDiskLog ("Building sparse index image {0} ({1} logical) from seed {2} ({3} files, {4:N2} GB)..." -f ${ImagePath}, ${SizeArg}, ${SeedDir}, ${seedFiles}.Count, ${seedGb})

    New-SparseBackingFile -Path ${ImagePath} -Bytes ${SizeBytes}
    Write-ImDiskLog ("Created sparse backing file ({0:N0} bytes logical, sparse)." -f ${SizeBytes})

    ${scratch} = Get-FreeDriveLetter
    ${scratchVol} = "{0}:" -f ${scratch}
    ${scratchRoot} = "{0}:\" -f ${scratch}
    Write-ImDiskLog ("Mounting scratch {0} to format + seed the image..." -f ${scratchVol})
    # FILE-backed on purpose (NO -t vm): the format + robocopy below must persist
    # into the backing .img so the seeded indexes survive. Only the RUNTIME D:
    # mounts (immediate + boot task) use -t vm. Do not add -t vm here.
    ${mountArgs} = @('-a', '-m', ${scratchVol}, '-s', ${SizeArg}, '-f', ${ImagePath})
    ${mp} = Start-Process -FilePath ${ImdiskExe} -ArgumentList ${mountArgs} -PassThru -Wait -WindowStyle Hidden
    try { ${mp}.Refresh() } catch {}
    if ($null -eq ${mp}.ExitCode -or ${mp}.ExitCode -ne 0) {
        throw ("imdisk -a -m {0} -s {1} (scratch build mount) failed (exit {2})." -f ${scratchVol}, ${SizeArg}, ${mp}.ExitCode)
    }
    # NOTE: do NOT probe ${scratchRoot} here. imdisk attach via Start-Process
    # -Wait is synchronous (the drive letter is assigned on return), but the
    # image is still RAW/unformatted at this point, so Test-Path on the root
    # returns $false until the format below lays down a filesystem. Probing the
    # root now would falsely fail. We verify the root AFTER formatting instead.

    try {
        # QUICK NTFS format. /Y suppresses the proceed prompt; /V sets the label
        # so format does not stop to ask for one. Quick format only writes FS
        # metadata, so the sparse backing file stays small.
        Write-ImDiskLog ("Quick-formatting {0} as NTFS (label {1})..." -f ${scratchVol}, ${IndexSubdir})
        ${fmtArgs} = @(${scratchVol}, '/FS:NTFS', '/Q', '/Y', ('/V:{0}' -f ${IndexSubdir}))
        ${fp} = Start-Process -FilePath 'format.com' -ArgumentList ${fmtArgs} -PassThru -Wait -WindowStyle Hidden
        try { ${fp}.Refresh() } catch {}
        if ($null -eq ${fp}.ExitCode -or ${fp}.ExitCode -ne 0) {
            throw ("format {0} /FS:NTFS /Q failed (exit {1})." -f ${scratchVol}, ${fp}.ExitCode)
        }
        if (-not (Wait-ForDriveRoot -Root ${scratchRoot})) {
            throw ("Scratch volume {0} did not surface after format." -f ${scratchVol})
        }

        ${dest} = Join-Path ${scratchRoot} ${IndexSubdir}
        Write-ImDiskLog ("Seeding index files: {0} -> {1}" -f ${SeedDir}, ${dest})
        ${rcOut} = & robocopy "${SeedDir}" "${dest}" '/E' '/COPY:DAT' '/R:1' '/W:1' '/NFL' '/NDL' '/NJH' '/NP' 2>&1
        ${rc} = ${LASTEXITCODE}
        foreach (${line} in ${rcOut}) {
            Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[robocopy] {0}" -f ${line})
        }
        # robocopy: 0-7 are success/info, >=8 indicates at least one failure.
        if (${rc} -ge 8) {
            throw ("robocopy of index seed failed (exit {0})." -f ${rc})
        }
        ${copied} = @(Get-ChildItem -LiteralPath ${dest} -File -Recurse -ErrorAction SilentlyContinue)
        Write-ImDiskLog ("Index seed copied: {0} files in {1} (robocopy rc={2})." -f ${copied}.Count, ${dest}, ${rc})
        if (${copied}.Count -eq 0) {
            throw ("No index files present in {0} after robocopy." -f ${dest})
        }
    }
    finally {
        # Detach the scratch mount so the backing file is flushed and the final
        # boot/immediate mount can claim it at D:. Guarded: imdisk writes errors
        # to stderr, which EAP=Stop turns into a fresh throw inside this finally
        # block -- that must never mask the real error from the try body above
        # (it hid the original format failure in the Y:-was-a-DVD incident).
        Write-ImDiskLog ("Detaching scratch {0}..." -f ${scratchVol})
        try {
            ${detachOut} = & ${ImdiskExe} -D -m ${scratchVol} 2>&1
            foreach (${line} in @(${detachOut})) {
                Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[imdisk] {0}" -f ${line})
            }
        } catch {
            Write-ImDiskLog ("[WARN] scratch detach of {0} failed: {1}" -f ${scratchVol}, $_.Exception.Message)
        }
        Wait-ForDriveRoot -Root ${scratchRoot} -Gone | Out-Null
    }

    if (Test-Path -LiteralPath ${ImagePath}) {
        Write-ImDiskLog ("Sparse index image built: {0} ({1:N2} GB logical)." -f ${ImagePath}, ((Get-Item ${ImagePath}).Length / 1GB))
    } else {
        throw ("Image build reported success but {0} is missing." -f ${ImagePath})
    }
}

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

    # Build the sparse 32 GB index image from the staged seed, unless it is
    # already present at the persistent path (idempotent re-runs, or a unit
    # where the image was pre-built / built on a previous provision). The seed
    # is just the index FITS files (staged by build-mast as <payload>\mast-indexes);
    # the unit owns turning those into the sparse D: image.
    if (Test-Path -LiteralPath ${ImagePath}) {
        Write-ImDiskLog ("Index image already present at {0} ({1:N2} GB logical); reusing as-is." -f ${ImagePath}, ((Get-Item ${ImagePath}).Length / 1GB))
    } elseif (Test-Path -LiteralPath ${IndexSeedDir}) {
        Build-SparseIndexImage -ImagePath ${ImagePath} -SeedDir ${IndexSeedDir} `
            -SizeBytes ${DiskSizeBytes} -SizeArg ${DiskSize} -ImdiskExe ${imdiskExe} -IndexSubdir ${IndexSubdir}
    } else {
        Write-ImDiskLog ("[WARN] No image at {0} and no index seed at {1}. D:\{2} will be empty; astrometry + mast-validation will FAIL." -f ${ImagePath}, ${IndexSeedDir}, ${IndexSubdir})
    }

    Write-ImDiskLog "Creating boot-time RAM-backed (-t vm) volatile mount scheduled task..."
    # -t vm: load the image into RAM at attach; runtime writes are volatile.
    # Size is taken from the image file, so no -s here (unlike the build mount).
    ${argLine} = ('-a -m D: -t vm -f "{0}"' -f ${ImagePath})
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
        -Description ("Mount D: from {0} on system startup (ImDisk -t vm: RAM-backed, VOLATILE - index seed loads into RAM, runtime scratch wiped on reboot)" -f ${ImagePath}) `
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
    ${dDisk} = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='D:'" -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath ${ImagePath})) {
        Write-ImDiskLog ("[INFO] Skipping immediate mount: image not present at {0}. Boot task will pick it up later." -f ${ImagePath})
    } elseif (${dDisk} -and ${dDisk}.DriveType -eq 3 -and ${dDisk}.VolumeName -eq ${IndexSubdir}) {
        Write-ImDiskLog "[INFO] D: already carries the index volume; skipping immediate mount. Existing mount left intact."
    } elseif (${dDisk} -or (Test-Path -LiteralPath 'D:\')) {
        # A foreign device parked on D: (DVD drive, card reader, ...) breaks the
        # fleet-standard index mount -- and the boot task would fail the same
        # way. Fail loudly instead of mounting elsewhere or skipping silently.
        ${dDesc} = 'unknown device'
        if (${dDisk}) { ${dDesc} = ('DriveType={0} label=''{1}''' -f ${dDisk}.DriveType, ${dDisk}.VolumeName) }
        throw ("D: is taken by another device ({0}); the MAST index RAM disk requires D:. Reassign that device's letter and re-run." -f ${dDesc})
    } else {
        Write-ImDiskLog ("Mounting D: from {0} via ImDisk (immediate, -t vm RAM-backed) ..." -f ${ImagePath})
        ${mountArgs} = @('-a', '-m', 'D:', '-t', 'vm', '-f', ${ImagePath})
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
        if (-not (Wait-ForDriveRoot -Root 'D:\' -TimeoutMs 2000)) {
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
