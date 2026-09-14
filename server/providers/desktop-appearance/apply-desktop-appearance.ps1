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
    [string]${AppearanceRoot} = 'C:\ProgramData\MAST\desktop',
    #: Same default as verify-desktop-appearance.ps1; read only to re-derive the
    #: fields when the image has gone stale.
    [string]${UnitToml} = 'C:\WIS\config.toml'
)

${ErrorActionPreference} = 'Stop'

${SidecarPath} = Join-Path ${AppearanceRoot} 'background.json'
${LogFile}     = Join-Path ${AppearanceRoot} 'apply.log'

# SystemParametersInfo / WM_SETTINGCHANGE constants.
${SPI_SETDESKWALLPAPER} = 0x0014
${SPIF_UPDATEINIFILE}   = 0x01
${SPIF_SENDCHANGE}      = 0x02
${HWND_BROADCAST}       = [System.IntPtr]0xffff
${WM_SETTINGCHANGE}     = 0x001A
${SMTO_ABORTIFHUNG}     = 0x0002
${BroadcastTimeoutMs}   = 1000

${libPath} = Join-Path ${PSScriptRoot} 'mast-appearance-lib.ps1'
if (-not (Test-Path ${libPath})) { throw "mast-appearance-lib.ps1 not found next to apply-desktop-appearance.ps1" }
. ${libPath}

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

    # Re-render before applying when the image no longer describes this machine.
    #
    # The provisioning date is the field that goes stale on its own: it changes on
    # every run, while this provider only re-renders on a run that TARGETED it,
    # which per-module drift makes the exception rather than the rule. mast07
    # displayed "provisioned 2026-09-02" for twelve days and two provisioning runs
    # (#200). Comparing here means a reboot corrects it with no provisioning at
    # all, and it costs a string compare on the runs where nothing has changed.
    #
    # Failure here is deliberately not fatal: a stale-but-present wallpaper beats
    # no wallpaper, and verify-desktop-appearance.ps1 reports the staleness so the
    # next run repairs it rather than leaving it to this task to keep retrying.
    ${fresh} = Get-MastAppearanceFields -UnitToml ${UnitToml}
    if (${sidecar}.static_fields.provisioned -ne ${fresh}.provisioned) {
        Write-ApplyLog ("background is stale: depicts '{0}', machine reports '{1}'; re-rendering." -f `
            ${sidecar}.static_fields.provisioned, ${fresh}.provisioned)
        try {
            & (Join-Path ${AppearanceRoot} 'render-desktop-background.ps1') `
                -OutputPath ${sidecar}.image -SidecarPath ${SidecarPath} `
                -ComputerName (${fresh}.computer_name) -SiteCode (${fresh}.site) -SiteName (${fresh}.site_name) `
                -Coordinates (${fresh}.coordinates) -Provisioned (${fresh}.provisioned)
            ${sidecar} = Get-Content -LiteralPath ${SidecarPath} -Raw | ConvertFrom-Json
        } catch {
            Write-ApplyLog ("WARNING: re-render failed, applying the existing image: " + $_.Exception.Message)
        }
    }

    ${imagePath} = ${sidecar}.image
    if (-not (Test-Path -LiteralPath ${imagePath})) {
        throw ("background image named by the sidecar is missing: {0}" -f ${imagePath})
    }

    # The same table the provider wrote into this hive from the provisioning session --
    # theme, wallpaper, toast and content-delivery quieting. Re-asserted rather than
    # assumed: this runs as the owner of HKCU, so it is the one place that can be sure
    # the values are the ones the live session will read.
    ${userValues} = Get-MastDesktopUserValues -WallpaperPath ${imagePath}
    foreach (${value} in ${userValues}) {
        ${keyPath} = Join-Path 'HKCU:' ${value}.SubKey
        if (-not (Test-Path -LiteralPath ${keyPath})) { New-Item -Path ${keyPath} -Force | Out-Null }
        Set-ItemProperty -LiteralPath ${keyPath} -Name ${value}.Name -Value ${value}.Value -Type ${value}.Type -Force
    }
    Write-ApplyLog ("Asserted {0} per-user values in HKCU (image {1})." -f ${userValues}.Count, ${imagePath})

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
