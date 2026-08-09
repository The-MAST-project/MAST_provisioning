#requires -Version 5.1
[CmdletBinding()]
param(
    # Where the boot/pre-start mount script is installed on the unit.
    [string]${MountScript} = 'C:\MAST\mast-mount-shared.ps1',
    [string]${TaskName}    = 'MAST-Mount-Shared',
    [string]${StatusPath}  = 'C:\MAST\status\shared-mount.json',
    # The service whose nssm Start/Pre hook re-asserts the mapping. Installed by
    # the 'mast' provider (order 2200), which is why this provider runs after it.
    [string]${UnitService} = 'mast-unit',
    [string]${Letter}      = 'Z'
)

# Establishes Z: as the unit's OPERATIONAL shared drive -- \\<controller_host>\mast-share
# on the site control machine -- in the LOCAL SYSTEM logon session.
#
# Provisioning used to map Z: to \\<ProvServer>\mast-shared from execute, which is
# wrong twice over: the letter belongs to the operational store (MAST_common's Filer
# roots its 'shared' area on Z:\MAST\<hostname>\ and the ram-to-shared mover writes
# every exposure there), and a mapping made in the provisioning user's session is not
# visible to the LocalSystem services that actually use it. See issue #25 and the
# DECISIONS entry.
#
# Two mechanisms, one script (server/providers/mast-shared-mount/assets/mast-mount-shared.ps1):
#   1. A SYSTEM scheduled task at startup -- the mapping exists for every LocalSystem
#      process from boot, and retries if the network is not up yet.
#   2. An nssm Start/Pre hook on mast-unit -- closes the boot race deterministically:
#      the mapping is re-asserted immediately before the unit process starts, in the
#      same SYSTEM session it will run in.
#
# Best-effort on the mount itself: a unit provisioned in the lab cannot reach the site
# controller, and that must not fail the run. The INSTALL (script, task, hook) is not
# best-effort -- a failure there is a real provisioning failure.

${ErrorActionPreference} = 'Stop'

${logRoot}   = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'logs'
${verifyLog} = Join-Path ${logRoot} 'verify\mast-shared-mount-verify.log'
${smokeFile} = Join-Path ${logRoot} 'smoke\mast-shared-mount-smoke.txt'
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${verifyLog}) -ErrorAction SilentlyContinue
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${smokeFile}) -ErrorAction SilentlyContinue

${mastLogDot} = Join-Path ${PSScriptRoot} 'mast-log.ps1'
if (-not (Test-Path ${mastLogDot})) { ${mastLogDot} = Join-Path ${PSScriptRoot} '..\..\lib\mast-log.ps1' }
. ${mastLogDot}
${logDir} = Get-MastLogSessionDir
${null} = New-Item -ItemType Directory -Path ${logDir} -Force -ErrorAction SilentlyContinue
${logFile} = Join-Path ${logDir} 'mast-shared-mount.log'

function Write-MLog {
    param([string]${Line})
    Write-MastLog -Message ${Line} -LogFile ${logFile}
}
function Write-Smoke {
    param([string]${Body})
    Set-Content -LiteralPath ${smokeFile} -Value ${Body} -Encoding UTF8 -Force
}

Write-MLog 'provide-mast-shared-mount.ps1 started.'

# --- 1. Install the mount script ---------------------------------------------
# build flattens 'assets/*' to the staging root, so the asset sits beside this script.
${src} = Join-Path ${PSScriptRoot} 'mast-mount-shared.ps1'
if (-not (Test-Path -LiteralPath ${src})) {
    ${src} = Join-Path ${PSScriptRoot} 'assets\mast-mount-shared.ps1'
}
if (-not (Test-Path -LiteralPath ${src})) {
    throw "mast-mount-shared.ps1 not staged (expected beside this script or under assets\)."
}
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${MountScript}) -ErrorAction SilentlyContinue
Copy-Item -LiteralPath ${src} -Destination ${MountScript} -Force
Write-MLog ("Installed mount script -> {0}" -f ${MountScript})

# --- 2. Drop any per-user mapping of the letter -------------------------------
# Provisioning itself created these (persistent, pointing at the prov server), and
# they are what a human sees as 'Unavailable' in `net use`. They are invisible to the
# services either way, so they carry no information -- only confusion. Clearing them
# makes an already-provisioned unit converge on the single meaning of the letter.
${root} = "{0}:" -f ${Letter}
${userMapKey} = "HKCU:\Network\{0}" -f ${Letter}
if (Test-Path -LiteralPath ${userMapKey}) {
    ${stale} = (Get-ItemProperty -LiteralPath ${userMapKey} -ErrorAction SilentlyContinue).RemotePath
    & cmd.exe /c "net use ${root} /delete /yes >nul 2>&1"
    Remove-Item -LiteralPath ${userMapKey} -Recurse -Force -ErrorAction SilentlyContinue
    Write-MLog ("Removed stale per-user {0} mapping ({1})." -f ${root}, ${stale})
} else {
    Write-MLog ("No per-user {0} mapping to remove." -f ${root})
}

# --- 3. SYSTEM scheduled task at startup --------------------------------------
# LogonType ServiceAccount: runs in the LocalSystem logon session, the one the
# nssm-installed MAST services share. RestartCount covers a boot where the network
# (or the controller) is not up yet.
${arg} = ('-NoProfile -ExecutionPolicy Bypass -NonInteractive -File "{0}"' -f ${MountScript})
${act}  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ${arg}
${trg}  = New-ScheduledTaskTrigger -AtStartup
${trg}.Delay = 'PT30S'
${prin} = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
${set}  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 2)
${null} = Register-ScheduledTask -TaskName ${TaskName} -Action ${act} -Trigger ${trg} `
    -Principal ${prin} -Settings ${set} -Force
Write-MLog ("Registered startup task '{0}' (SYSTEM)." -f ${TaskName})

# --- 4. nssm Start/Pre hook on the unit service -------------------------------
# Fixed install path, like the mast provider: the nssm provider adds it to the machine
# PATH, but this session's PATH predates that, so a lookup by name can miss.
${nssmExe} = 'C:\Program Files\nssm\nssm.exe'
${nssmOk} = Test-Path -LiteralPath ${nssmExe}
${svc} = Get-Service -Name ${UnitService} -ErrorAction SilentlyContinue
if (${nssmOk} -and ${svc}) {
    ${hook} = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File "{0}"' -f ${MountScript})
    & ${nssmExe} set ${UnitService} AppEvents ('Start/Pre=' + ${hook}) | Out-Null
    Write-MLog ("Set nssm Start/Pre hook on {0}." -f ${UnitService})
} else {
    # Not fatal: a modules-filtered run may provision this module without the mast
    # provider having installed the service. The startup task still covers boot.
    Write-MLog ("[WARN] skipped nssm Start/Pre hook (nssm present: {0}, {1} registered: {2})." -f `
        ${nssmOk}, ${UnitService}, [bool]${svc})
}

# --- 5. Mount now and report ---------------------------------------------------
# Run it through the task so the mapping lands in the SYSTEM session -- running the
# script inline here would map the letter into the provisioning user's session, which
# is precisely the bug being fixed.
Remove-Item -LiteralPath ${StatusPath} -Force -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName ${TaskName}
${deadline} = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt ${deadline} -and -not (Test-Path -LiteralPath ${StatusPath})) {
    Start-Sleep -Seconds 3
}

if (-not (Test-Path -LiteralPath ${StatusPath})) {
    Write-MLog ("[WARN] mount task wrote no status within 120s (task '{0}')." -f ${TaskName})
    Write-Smoke 'shared_mount_warn reason=no_status'
    exit 0
}

${status} = Get-Content -LiteralPath ${StatusPath} -Raw | ConvertFrom-Json
if (${status}.ok) {
    Write-MLog ("{0} -> {1} ({2})." -f ${root}, ${status}.target, ${status}.detail)
    Write-Smoke ("shared_mount_ok target=" + ${status}.target)
} else {
    Write-MLog ("[WARN] {0} not mapped: {1}" -f ${root}, ${status}.detail)
    Write-MLog '       The unit will fall back to C:\MAST for exposures until this is fixed'
    Write-MLog '       (MAST_common Filer.accessible_shared_root). Expected when provisioning'
    Write-MLog '       off-site: the site controller is unreachable from the lab.'
    Write-Smoke ("shared_mount_warn reason=" + (${status}.detail -replace '\s+', '_'))
}
exit 0
