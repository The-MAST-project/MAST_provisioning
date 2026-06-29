#requires -Version 5.1
[CmdletBinding()]
param(
    # Ordered NTP priority tiers. Each tier may hold one or more space-separated
    # hosts; blank tiers are skipped. RpiNtp is SITE-SPECIFIC (e.g. the Neot Smadar
    # RPi) and is injected per-site by build-mast.ps1 -Site -- empty for sites with
    # none. The provisioning server (tier 3) is auto-discovered if not passed.
    [string]${RpiNtp}        = '',
    [string]${WeizmannNtp}   = 'ntp.weizmann.ac.il ntp2.weizmann.ac.il',
    [string]${ProvServer}    = '',
    [string]${WindowsNtp}    = 'time.windows.com',
    [int]   ${ResyncRetries} = 3
)

# Early clock correction + ongoing NTP config during provisioning.
#
# MAST units frequently cannot reach public NTP (UDP 123 blocked / no internet
# route), and a wrong clock breaks the 'mast' git clone's TLS validation and
# destabilizes long WinRM sessions. We configure an ORDERED time-server priority
# list and correct the clock once here, before any HTTPS/TLS step.
#
# Priority (the one-time correction probes these in STRICT order; first that locks
# wins):  1. RPi @ site  2. Weizmann internal NTP  3. provisioning server
# (auto-discovered)  4. time.windows.com.
#
# Steady state (the config the unit KEEPS): ALL non-blank tiers go into the w32time
# manualpeerlist together; w32time then auto-selects the best by stratum/dispersion
# and fails over -- so the order is advisory for steady state. Unlike the old design,
# the provisioning server stays PERMANENTLY in the ongoing list (tier 3), not just a
# one-time source -- it is a reliable low-stratum peer on the same network. See
# DECISIONS.md 2026-06-29. Best-effort: a clock that will not sync is logged loudly
# but does NOT abort the run.

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

# --- Build the ordered priority tiers (skip blanks) ---------------------------
${tiers} = @()
if (${RpiNtp})      { ${tiers} += [pscustomobject]@{ Name = 'rpi';      Peers = ${RpiNtp} } }
if (${WeizmannNtp}) { ${tiers} += [pscustomobject]@{ Name = 'weizmann'; Peers = ${WeizmannNtp} } }
if (${ProvServer})  { ${tiers} += [pscustomobject]@{ Name = 'prov';     Peers = ("{0},0x8" -f ${ProvServer}) } }
if (${WindowsNtp})  { ${tiers} += [pscustomobject]@{ Name = 'windows';  Peers = ${WindowsNtp} } }
if (-not ${ProvServer}) {
    Write-TLog '[WARN] could not determine the provisioning server (no mast SMB connection / Z: mapping); skipping tier 3.'
}
${tierDesc} = (${tiers} | ForEach-Object { ${_}.Name + '=' + ${_}.Peers }) -join ' | '
Write-TLog ("Ordered NTP tiers: {0}" -f ${tierDesc})

# --- One-time correction: probe tiers in STRICT priority order ----------------
${syncedSource} = ''
${syncedVia}    = ''
foreach (${tier} in ${tiers}) {
    Write-TLog ("One-time sync attempt: tier '{0}' ({1}) ..." -f ${tier}.Name, ${tier}.Peers)
    ${syncedSource} = Invoke-W32TimeSync -PeerList ${tier}.Peers
    if (${syncedSource}) { ${syncedVia} = ${tier}.Name; break }
}

# --- Steady state: ALL tiers in the ongoing manualpeerlist (prov PERMANENT) ---
# w32time auto-selects the best peer and fails over; we do not resync again here
# (the clock is already corrected above, and an unreachable peer must not undo it).
${steadyPeers} = (${tiers} | ForEach-Object { ${_}.Peers }) -join ' '
& w32tm.exe /config /manualpeerlist:"${steadyPeers}" /syncfromflags:manual /reliable:no /update | Out-Null
Restart-Service -Name w32time -ErrorAction SilentlyContinue
Write-TLog ("Left w32time with ongoing peer list: {0}" -f ${steadyPeers})

if (${syncedSource}) {
    Write-TLog ("Clock corrected (via {0}, source={1}); now {2}." -f ${syncedVia}, ${syncedSource}, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Smoke ("timesync_ok via=" + ${syncedVia})
} else {
    Write-TLog '[WARN] could not correct the clock from any NTP tier (RPi/Weizmann/prov/Windows).'
    Write-TLog '       Continuing best-effort (is UDP 123 reachable to any tier? is the prov NTP server up?);'
    Write-TLog '       a wrong clock will break the HTTPS git clone -- fix NTP reachability or set the clock manually.'
    Write-Smoke 'timesync_warn reason=not_locked'
}
exit 0
