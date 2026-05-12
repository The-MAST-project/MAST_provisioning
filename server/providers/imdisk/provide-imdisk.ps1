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

    Write-ImDiskLog "Creating boot-time ramdisk activation scheduled task..."
    ${taskName} = "MAST-ImDisk-Ramdisk"
    ${taskAction} = New-ScheduledTaskAction -Execute ${imdiskExe} -Argument "-a -t vm -s 10G -m D: -p `"/fs:ntfs /q /y`""
    ${taskTrigger} = New-ScheduledTaskTrigger -AtStartup
    ${taskPrincipal} = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Unregister-ScheduledTask -TaskName ${taskName} -ErrorAction SilentlyContinue -Confirm:$false
    Register-ScheduledTask -TaskName ${taskName} `
        -Description "Create ImDisk 10GB ramdisk at D: on system startup" `
        -Action ${taskAction} `
        -Trigger ${taskTrigger} `
        -Principal ${taskPrincipal} `
        -ErrorAction Stop | Out-Null
    Write-ImDiskLog ("Scheduled task created: {0}" -f ${taskName})

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
