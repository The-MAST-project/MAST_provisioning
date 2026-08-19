# Phase 2: make the appearance visible in the mast user's live session.
#
# Registered by provide-desktop-appearance.ps1 (phase 1) as an AtLogon scheduled
# task running as 'mast', non-elevated, inside the logon session -- which is the
# only place the last two steps here can happen at all. Phase 1 already wrote the
# same registry values into mast's hive from the provisioning session; what it
# could not do is tell the running desktop about them. A registry write does not
# repaint a wallpaper and does not re-read the theme: SystemParametersInfo and the
# WM_SETTINGCHANGE broadcast have to come from inside the session.
#
# NOT one-shot, and no sentinel -- deliberately unlike
# apply-instrument-profiles.ps1, which materializes files once and unregisters
# itself. Appearance is standing state, not a one-time copy: the image is
# re-rendered when the machine is renamed or the design changes, and every reboot
# needs the broadcast again. A sentinel here would pin whatever the first logon
# happened to see.
#
# The image path comes from the sidecar, not from a constant, so this script keeps
# working when the image moves -- which is what the dynamic-content growth path
# does (see render-desktop-background.ps1).

[CmdletBinding()]
param(
    [string]${AppearanceRoot} = 'C:\ProgramData\MAST\desktop'
)

${ErrorActionPreference} = 'Stop'

${SidecarPath}     = Join-Path ${AppearanceRoot} 'background.json'
${LogFile}         = Join-Path ${AppearanceRoot} 'apply.log'
${ThemeKey}        = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
${DesktopKey}      = 'Control Panel\Desktop'
${WallpaperFill}   = '10'
${TileWallpaperNo} = '0'

# SystemParametersInfo / WM_SETTINGCHANGE constants.
${SPI_SETDESKWALLPAPER} = 0x0014
${SPIF_UPDATEINIFILE}   = 0x01
${SPIF_SENDCHANGE}      = 0x02
${HWND_BROADCAST}       = [System.IntPtr]0xffff
${WM_SETTINGCHANGE}     = 0x001A
${SMTO_ABORTIFHUNG}     = 0x0002
${BroadcastTimeoutMs}   = 1000

function Write-ApplyLog {
    param([string]${Line})
    ${stamp} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${LogFile} -Encoding UTF8 -Value ("[{0}] [{1}] {2}" -f ${stamp}, ${env:USERNAME}, ${Line})
}

try {
    New-Item -ItemType Directory -Path ${AppearanceRoot} -Force | Out-Null

    # No -UsingNamespace here. Add-Type -MemberDefinition already emits
    # `using System.Runtime.InteropServices;` itself, and adding it again makes the
    # compiler warn about the duplicate directive -- which it treats as an ERROR, so
    # Add-Type throws and this script dies. Measured on the dev VM 2026-08-19: the
    # task exited 1 before reaching any log line, and the only trace was the task's
    # own LastTaskResult. Inside the try for the same reason -- a failure up here has
    # to reach the catch, or it is invisible.
    if (-not ('MastProvisioning.DesktopInterop' -as [type])) {
        Add-Type -Namespace 'MastProvisioning' -Name 'DesktopInterop' -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, string pvParam, uint fWinIni);

[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
'@
    }

    if (-not (Test-Path -LiteralPath ${SidecarPath})) {
        throw ("background sidecar not found at {0} (provide-desktop-appearance.ps1 has not run on this machine)" -f ${SidecarPath})
    }
    ${sidecar} = Get-Content -LiteralPath ${SidecarPath} -Raw | ConvertFrom-Json
    ${imagePath} = ${sidecar}.image
    if (-not (Test-Path -LiteralPath ${imagePath})) {
        throw ("background image named by the sidecar is missing: {0}" -f ${imagePath})
    }

    # Dark theme. Two values: application chrome and the shell (taskbar, Start).
    ${themePath} = Join-Path 'HKCU:' ${ThemeKey}
    if (-not (Test-Path -LiteralPath ${themePath})) { New-Item -Path ${themePath} -Force | Out-Null }
    Set-ItemProperty -LiteralPath ${themePath} -Name 'AppsUseLightTheme'   -Value 0 -Type DWord -Force
    Set-ItemProperty -LiteralPath ${themePath} -Name 'SystemUsesLightTheme' -Value 0 -Type DWord -Force

    # Wallpaper. WallpaperStyle and TileWallpaper are REG_SZ, not DWORD -- written
    # as numbers they are ignored and the image lands centered and untiled.
    ${desktopPath} = Join-Path 'HKCU:' ${DesktopKey}
    Set-ItemProperty -LiteralPath ${desktopPath} -Name 'Wallpaper'      -Value ${imagePath}       -Type String -Force
    Set-ItemProperty -LiteralPath ${desktopPath} -Name 'WallpaperStyle' -Value ${WallpaperFill}   -Type String -Force
    Set-ItemProperty -LiteralPath ${desktopPath} -Name 'TileWallpaper'  -Value ${TileWallpaperNo} -Type String -Force
    Write-ApplyLog ("Asserted theme + wallpaper values in HKCU (image {0})." -f ${imagePath})

    ${applied} = [MastProvisioning.DesktopInterop]::SystemParametersInfo(
        ${SPI_SETDESKWALLPAPER}, 0, ${imagePath}, (${SPIF_UPDATEINIFILE} -bor ${SPIF_SENDCHANGE}))
    if (${applied}) { Write-ApplyLog 'Wallpaper applied to the live session.' }
    else { Write-ApplyLog ("[WARN] SystemParametersInfo returned false (Win32 error {0})." -f [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()) }

    # Tells the shell and every running app to re-read the theme. Without it the
    # dark switch waits for the next sign-in. A few Explorer surfaces follow only
    # after explorer.exe restarts, which is not done here: provisioning may be
    # running against a session that is observing.
    ${result} = [System.IntPtr]::Zero
    [void][MastProvisioning.DesktopInterop]::SendMessageTimeout(
        ${HWND_BROADCAST}, ${WM_SETTINGCHANGE}, [System.IntPtr]::Zero, 'ImmersiveColorSet',
        ${SMTO_ABORTIFHUNG}, ${BroadcastTimeoutMs}, [ref]${result})
    Write-ApplyLog 'Broadcast ImmersiveColorSet.'

    exit 0
}
catch {
    Write-ApplyLog ("FAILED: {0}" -f $_)
    exit 1
}
