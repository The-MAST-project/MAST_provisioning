#requires -Version 5.1
[CmdletBinding()]
param(
    [string]${ProvServer}    = '',
    # Servers the unit uses for NORMAL ongoing operation (the end state this
    # provider leaves behind). The prov server is only a one-time source.
    [string]${NormalNtp}     = 'time.windows.com pool.ntp.org time.google.com',
    [int]   ${ResyncRetries} = 3
)

# Early, ONE-TIME time correction during provisioning.
#
# MAST units frequently cannot reach public NTP (UDP 123 blocked / no internet
# route), so a wrong clock would break the 'mast' git clone's TLS validation and
# destabilize long WinRM sessions. The provisioning server IS reachable and runs
# an NTP server (server/setup-ntp-server.ps1), so we use it to correct the clock
# ONCE here -- then we leave w32time configured for normal public NTP for ongoing
# operation. We do NOT leave the unit permanently pointed at the prov server (it
# is not a long-lived time source for the unit).
#
# Order of preference for the one-time correction: prov server first (reliable
# during provisioning), then public NTP as a fallback. Best-effort throughout:
# a clock that will not sync is logged loudly but does NOT abort the run (the
# bootstrap public-NTP attempt and a manual fix are redundant backstops).

${ErrorActionPreference} = 'Stop'

${logRoot}   = Join-Path (Join-Path ${env:SystemDrive} 'MAST') 'logs'
${verifyLog} = Join-Path ${logRoot} 'verify\timesync-verify.log'
${smokeFile} = Join-Path ${logRoot} 'smoke\timesync-smoke.txt'
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${verifyLog}) -ErrorAction SilentlyContinue
${null} = New-Item -ItemType Directory -Force -Path (Split-Path -Parent ${smokeFile}) -ErrorAction SilentlyContinue

function Write-TLog {
    param([string]${Line})
    ${ts} = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath ${verifyLog} -Encoding UTF8 -Value ("[{0}] {1}" -f ${ts}, ${Line})
    Write-Host ${Line}
}
function Write-Smoke { param([string]${Value}) Set-Content -LiteralPath ${smokeFile} -Value ${Value} -Encoding ASCII }

# Configure w32time peers, resync, and report whether it actually locked on.
# Does NOT trust 'w32tm /resync's exit code (it returns success even when no NTP
# reply arrives and the service silently keeps the Local CMOS Clock).
function Invoke-W32TimeSync {
    param([string]${PeerList})
    & w32tm.exe /config /manualpeerlist:"${PeerList}" /syncfromflags:manual /reliable:no /update | Out-Null
    Restart-Service -Name w32time -ErrorAction SilentlyContinue
    for (${i} = 1; ${i} -le ${ResyncRetries}; ${i}++) {
        & w32tm.exe /resync /force | Out-Null
        Start-Sleep -Seconds 2
        ${status}   = & w32tm.exe /query /status 2>$null
        ${srcLine}  = (${status} | Select-String -Pattern 'Source:\s*(.+)$')
        ${lastLine} = (${status} | Select-String -Pattern 'Last Successful Sync Time:\s*(.+)$')
        ${source}   = if (${srcLine})  { ${srcLine}.Matches[0].Groups[1].Value.Trim() }  else { '' }
        ${lastSync} = if (${lastLine}) { ${lastLine}.Matches[0].Groups[1].Value.Trim() } else { '' }
        if (${source} -and (${source} -notmatch 'Local CMOS Clock') -and (${source} -notmatch 'Free-running') `
                -and ${lastSync} -and (${lastSync} -notmatch 'unspecified')) {
            return ${source}
        }
        Write-TLog ("  resync attempt {0}/{1} ({2}): not locked yet (Source='{3}')" -f ${i}, ${ResyncRetries}, ${PeerList}, ${source})
    }
    return ''
}

Set-Content -LiteralPath ${verifyLog} -Encoding UTF8 `
    -Value ("[{0}] provide-timesync.ps1 started" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try {
    Set-Service -Name w32time -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name w32time -ErrorAction SilentlyContinue
} catch {}

# --- Discover the provisioning server (its NTP server) for the one-time sync ---
# The unit holds an SMB connection to the prov server (the mast-staging pull and
# the Z: -> \\<ProvServer>\mast-shared mapping done before any module runs).
if (-not ${ProvServer}) {
    try {
        ${conn} = Get-SmbConnection -ErrorAction SilentlyContinue |
            Where-Object { $_.ShareName -eq 'mast-shared' -or $_.ShareName -eq 'mast-staging' } |
            Select-Object -First 1
        if (${conn}) { ${ProvServer} = ${conn}.ServerName }
    } catch {}
}
if (-not ${ProvServer}) {
    ${z} = Get-PSDrive -Name Z -ErrorAction SilentlyContinue
    if (${z} -and ${z}.DisplayRoot -match '^\\\\([^\\]+)\\') { ${ProvServer} = ${Matches}[1] }
}

# --- One-time correction: prov server first, then public NTP as fallback ------
${syncedSource} = ''
${syncedVia}    = ''
if (${ProvServer}) {
    Write-TLog ("One-time sync from provisioning server {0} ..." -f ${ProvServer})
    ${syncedSource} = Invoke-W32TimeSync -PeerList ("{0},0x8" -f ${ProvServer})
    if (${syncedSource}) { ${syncedVia} = ("prov-server:" + ${ProvServer}) }
} else {
    Write-TLog '[WARN] could not determine the provisioning server (no mast SMB connection / Z: mapping).'
}
if (-not ${syncedSource}) {
    Write-TLog ("Falling back to public NTP for the one-time sync: {0}" -f ${NormalNtp})
    ${syncedSource} = Invoke-W32TimeSync -PeerList ${NormalNtp}
    if (${syncedSource}) { ${syncedVia} = 'public-ntp' }
}

# --- Leave w32time configured for NORMAL public NTP (not the prov server) -----
# This is the ongoing config the unit keeps after provisioning. We do not resync
# again here -- the clock is already corrected above; public NTP may be
# unreachable from the unit, and that must not undo the correction.
& w32tm.exe /config /manualpeerlist:"${NormalNtp}" /syncfromflags:manual /reliable:no /update | Out-Null
Restart-Service -Name w32time -ErrorAction SilentlyContinue
Write-TLog ("Left w32time configured for normal NTP: {0}" -f ${NormalNtp})

if (${syncedSource}) {
    Write-TLog ("Clock corrected (via {0}, source={1}); now {2}." -f ${syncedVia}, ${syncedSource}, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Smoke ("timesync_ok via=" + ${syncedVia})
} else {
    Write-TLog '[WARN] could not correct the clock from the prov server or public NTP.'
    Write-TLog '       Is the prov server running setup-ntp-server.ps1 (UDP 123 open)? Continuing best-effort;'
    Write-TLog '       a wrong clock will break the HTTPS git clone -- fix NTP reachability or set the clock manually.'
    Write-Smoke 'timesync_warn reason=not_locked'
}
exit 0
