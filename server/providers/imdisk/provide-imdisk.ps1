param(
    [string]${AssetsRoot} = "."
)

${ErrorActionPreference} = "Stop"
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "imdisk-install.log"

try {
    Write-Host "Starting ImDisk installation..."

    # Extract ImDisk archive
    ${zipPath} = Join-Path ${AssetsRoot} "ImDiskTk-x64.zip"
    if (-not (Test-Path ${zipPath})) {
        throw "ImDisk archive not found at ${zipPath}"
    }

    ${extractDir} = Join-Path ${env:TEMP} "imdisk-install"
    New-Item -ItemType Directory -Path ${extractDir} -Force | Out-Null

    Write-Host "Extracting ImDisk archive to ${extractDir}" | Tee-Object -FilePath ${logFile}
    Expand-Archive -Path ${zipPath} -DestinationPath ${extractDir} -Force

    # Find the subfolder (ImDiskTk20240113 or similar)
    ${subfolders} = Get-ChildItem -Path ${extractDir} -Directory | Where-Object { $_.Name -like "ImDiskTk*" }
    if (-not ${subfolders}) {
        throw "ImDiskTk subfolder not found in extracted archive"
    }

    ${installDir} = $subfolders[0].FullName
    Write-Host "Found ImDisk folder: $($subfolders[0].Name)" | Tee-Object -FilePath ${logFile} -Append

    # Run install.bat from subfolder
    ${installBat} = Join-Path ${installDir} "install.bat"
    if (-not (Test-Path ${installBat})) {
        throw "install.bat not found at ${installBat}"
    }

    Write-Host "Running install.bat" | Tee-Object -FilePath ${logFile} -Append
    & cmd.exe /c "${installBat} /silent" 2>&1 | Tee-Object -FilePath ${logFile} -Append

    if (${LASTEXITCODE} -ne 0) {
        Write-Host "WARNING: install.bat exited with code ${LASTEXITCODE}" | Tee-Object -FilePath ${logFile} -Append
    }

    # Verify ImDisk is available at System32
    ${imdiskExe} = "C:\Windows\System32\imdisk.exe"
    if (-not (Test-Path ${imdiskExe})) {
        throw "ImDisk executable not found at ${imdiskExe}"
    }

    Write-Host "ImDisk found at: ${imdiskExe}" | Tee-Object -FilePath ${logFile} -Append

    # Create scheduled task for ramdisk activation at boot
    Write-Host "Creating boot-time ramdisk activation task" | Tee-Object -FilePath ${logFile} -Append

    ${taskName} = "MAST-ImDisk-Ramdisk"
    ${taskDescription} = "Create ImDisk 10GB ramdisk at D: on system startup"
    # TBD: give imdisk.exe parameter with the pre-populated image file
    ${taskAction} = New-ScheduledTaskAction -Execute ${imdiskExe} -Argument "-a -t vm -s 10G -m D: -p `"/fs:ntfs /q /y`""
    ${taskTrigger} = New-ScheduledTaskTrigger -AtStartup
    ${taskPrincipal} = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    # Remove existing task if it exists
    Unregister-ScheduledTask -TaskName ${taskName} -ErrorAction SilentlyContinue -Confirm:$false

    Register-ScheduledTask -TaskName ${taskName} `
        -Description ${taskDescription} `
        -Action ${taskAction} `
        -Trigger ${taskTrigger} `
        -Principal ${taskPrincipal} `
        -ErrorAction Stop | Out-Null

    Write-Host "Scheduled task created: ${taskName}" | Tee-Object -FilePath ${logFile} -Append

    # Cleanup temp directory
    Remove-Item -Path ${extractDir} -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "ImDisk installation completed successfully" | Tee-Object -FilePath ${logFile} -Append
    exit 0
}
catch {
    ${errorMsg} = "ImDisk installation failed: $_"
    Write-Host ${errorMsg}
    ${errorMsg} | Out-File -FilePath ${logFile} -Append -Encoding UTF8
    exit 1
}
