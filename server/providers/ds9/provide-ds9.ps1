param(
    [string]${AssetsRoot} = ".",
    [string]${InstallRoot} = "C:\Program Files\SAOImageDS9",
    [string]${InstallerPattern} = "SAOImageDS9*.exe"
)

${ErrorActionPreference} = "Stop"
${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
New-Item -ItemType Directory -Path ${logDir} -Force | Out-Null
${logFile} = Join-Path ${logDir} "ds9-install.log"

function Write-Ds9Log {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}

Set-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ("[{0}] provide-ds9.ps1 started." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# SAOImage DS9 ships on Windows as a self-extracting archive ("SAOImageDS9 x.y.z
# Install.exe"): an MZ stub with a zip appended. DS9 is a standalone app that
# needs no real installation -- the supported "silent install" is simply to
# extract the archive and run ds9.exe from the result. We extract with the
# Windows in-box tar.exe (bsdtar/libarchive), which reads the trailing zip past
# the MZ prefix; .NET ZipArchive / Expand-Archive choke on the SFX prefix, so
# do not substitute them.

try {
    ${ds9Exe} = Join-Path ${InstallRoot} 'ds9.exe'

    # Idempotency: skip if ds9.exe is already extracted.
    if (Test-Path -LiteralPath ${ds9Exe}) {
        Write-Ds9Log ("ds9.exe already present at {0}; skipping extract." -f ${ds9Exe})
    } else {
        # Resolve assets dir: prefer .\assets next to this script, fall back to AssetsRoot.
        ${assetsDir} = Join-Path ${PSScriptRoot} 'assets'
        if (-not (Test-Path -LiteralPath ${assetsDir})) { ${assetsDir} = ${AssetsRoot} }

        ${candidates} = @(Get-ChildItem -Path ${assetsDir} -Filter ${InstallerPattern} -File -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending)
        if (${candidates}.Count -eq 0) {
            throw ("No DS9 installer matched '{0}' under {1}" -f ${InstallerPattern}, ${assetsDir})
        }
        ${installerPath} = ${candidates}[0].FullName
        Write-Ds9Log ("DS9 archive: {0}" -f ${installerPath})

        # Locate the in-box tar.exe (bsdtar). Get-Command may resolve a shim on
        # PATH; fall back to the System32 copy that ships with Windows 10/11.
        ${tarExe} = $null
        ${tarCmd} = Get-Command 'tar.exe' -ErrorAction SilentlyContinue
        if (${tarCmd}) { ${tarExe} = ${tarCmd}.Source }
        if (-not ${tarExe} -or -not (Test-Path -LiteralPath ${tarExe})) {
            ${sysTar} = Join-Path ${env:SystemRoot} 'System32\tar.exe'
            if (Test-Path -LiteralPath ${sysTar}) { ${tarExe} = ${sysTar} }
        }
        if (-not ${tarExe}) {
            throw "tar.exe (bsdtar) not found; required to extract the DS9 self-extracting archive."
        }

        New-Item -ItemType Directory -Path ${InstallRoot} -Force | Out-Null
        Write-Ds9Log ("Extracting with {0} -xf <archive> -C {1}" -f ${tarExe}, ${InstallRoot})
        & ${tarExe} -xf ${installerPath} -C ${InstallRoot}
        ${tarRc} = ${LASTEXITCODE}
        Write-Ds9Log ("tar exit code: {0}" -f ${tarRc})
        if (${tarRc} -ne 0) {
            throw ("tar.exe failed to extract DS9 archive (exit {0})" -f ${tarRc})
        }
    }

    if (-not (Test-Path -LiteralPath ${ds9Exe})) {
        throw ("DS9 executable not found after extract at {0}" -f ${ds9Exe})
    }

    # Start Menu shortcut (All Users) for parity with a normal install.
    try {
        ${startMenu} = Join-Path ${env:ProgramData} 'Microsoft\Windows\Start Menu\Programs'
        ${lnkPath}   = Join-Path ${startMenu} 'SAOImage DS9.lnk'
        ${wsh}       = New-Object -ComObject WScript.Shell
        ${sc}        = ${wsh}.CreateShortcut(${lnkPath})
        ${sc}.TargetPath       = ${ds9Exe}
        ${sc}.WorkingDirectory = ${InstallRoot}
        ${sc}.Description       = 'SAOImage DS9 astronomical imaging'
        ${sc}.Save()
        Write-Ds9Log ("Start Menu shortcut written: {0}" -f ${lnkPath})
    } catch {
        Write-Ds9Log ("[WARN] Could not create Start Menu shortcut: {0}" -f $_.Exception.Message)
    }

    Write-Ds9Log "DS9 installation completed successfully."
    exit 0
}
catch {
    ${errorMsg} = ("DS9 installation failed: {0}" -f $_)
    Write-Host ${errorMsg}
    Add-Content -LiteralPath ${logFile} -Encoding UTF8 -Value ${errorMsg}
    exit 1
}
