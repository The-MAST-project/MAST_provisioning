# Provisioning server setup guide

Step-by-step instructions for bringing up a Windows machine as the MAST
provisioning server - from a bare OS install to a running autonomous loop.

The guide assumes the reader is comfortable with Windows PowerShell and SMB
shares. It covers the production path and the dev/test variant (Windows host
running VirtualBox) in separate sections where they diverge.

---

## Prerequisites

**Operating system:** Windows 10 Pro/Enterprise (1903 or later) or Windows
Server 2019 or later. PowerShell 5.1 is included with all supported versions.
Do not use Home editions (no SMB server capability or local group policy).

**Hardware / disk:** At least 10 GB free in the repo checkout location. The
`staging\` tree holds one build per registered unit; each build is roughly
1-3 GB depending on enabled modules. Plan for `(unit count + 1) * 3 GB`.

**Network:**
- The provisioning server must be able to reach each unit by DNS hostname
  (`mast01`, `mast02`, ...). Units use DHCP; the hostname is the long-lived
  identity.
- TCP 5985 (WinRM HTTP) outbound to each unit. TCP 5986 (WinRM HTTPS) if you
  plan to use `-WinRMUseSSL`.
- TCP 445 (SMB) inbound from the unit subnet so units can pull their staging
  payload from `\\<prov-server-address>\mast-staging`. The driver hands each unit
  this server's **IP address on the route to that unit** — not its hostname — so
  no DNS record or `hosts` entry is needed on the units.
- ICMP echo (ping) outbound to units for the reachability check.

**Software on the provisioning server:**

| Tool | Required for | Notes |
|------|--------------|-------|
| Git 2.x | Cloning the repo | winget install Git.Git |
| Git LFS | Binary assets (installers, archives) | winget install GitHub.GitLFS |
| Python 3.12 | the driver itself (`server/prov/`), tools/run-remote-script-winrm.py | winget install Python.Python.3.12 |
| pywinrm + paramiko + tzdata | the driver's two transports and IANA timezone resolution | pip install -r server\requirements.txt |
| NSSM | supervising the loop as a Windows service | winget install NSSM.NSSM |

Python is required on the provisioning server: the driver itself is Python
(`server/check_and_provision.py` + the `server/prov/` package). Install its
dependencies with `pip install -r server\requirements.txt` -- pywinrm and paramiko for
the two transports, plus `tzdata` on Windows so `zoneinfo` can resolve the registry's
IANA timezone ids.

---

## Step 1 - Clone the repo

```powershell
git lfs install                   # one-time per machine; installs LFS hooks
git clone <repo-url> C:\repos\MAST_provisioning
cd C:\repos\MAST_provisioning
git lfs pull                      # download binary assets (installers, archives)
```

Verify that binary assets downloaded correctly - the `assets/` subdirectories
should contain real files, not LFS pointer stubs (1-2 KB text files starting
with `version https://git-lfs.github.com/spec/v1`):

```powershell
# Each file here should be >> 1 MB
Get-Item server\providers\python\assets\* | Select Name, Length
Get-Item server\providers\cygwin\assets\* | Select Name, Length
```

If you see pointer stubs, your LFS credentials are not set up. Configure them
(Credential Manager, deploy key, or PAT) and re-run `git lfs pull`.

---

## Step 1b - Build-host-local large assets (not in git)

A few payloads are too large to keep in the repo (even via LFS) and instead live
on the build host under `C:\MAST\`. `build-mast.ps1` stages them into each unit's
payload when the relevant module is enabled, and warns loudly (does not hard-block
the build) if they are missing. Populate these once per build host:

| Path | Needed by module | How to obtain |
|------|------------------|---------------|
| `C:\MAST\mast-indexes\` | `imdisk` (astrometry index seed) | `build\extract-index-seed.ps1` (once, from the legacy index image) |
| `C:\MAST\full-frame.fits` | `astrometry`, `mast-validation` (smoke solve input) | copy the reference solve FITS |
| `C:\MAST\ps3-catalog\Setup_PlateSolve3_Catalog.exe` + `Setup_PlateSolve3_Catalog-1.bin` | `planewave` (real PlateSolve3 catalog, ~1.9 GB) | download both parts from planewave.com (["installer part 1"](https://planewave.com/download/platesolve-3-catalog-installer-part-1-of-2-2/) + ["data part 2"](https://planewave.com/download/platesolve-3-catalog-data-part-2-of-2-2/)); keep the exact filenames so the `.bin` sits beside the `.exe` |

Without the PlateSolve3 catalog the `planewave` provider throws (no catalog to
install) and `ps3cli --server` cannot boot; without the index seed / smoke FITS the
astrometry stages fail on the unit.

---

## Step 2 - Populate vault/

`vault/` is gitignored. You must populate it before any provisioning can run.

### 2a. creds.json

Copy the template and fill in real values:

```powershell
Copy-Item vault\creds.json.template vault\creds.json
```

Edit `vault\creds.json`:

```json
{
    "unit": { "user": ".\\mast", "pass": "<password for the mast account on units>" },
    "smb":  { "user": "mast-transfer", "pass": "<strong password, >= 16 chars>" }
}
```

`unit` is the WinRM credential for connecting to unit machines. It must match
the password set by `client\bootstrap.ps1` during unit onboarding
(default dev value is `physics`; change it for production).

`smb` is a read-only local account that `setup-smb-share.ps1` creates on this
provisioning server. Units authenticate as `mast-transfer` to pull their
staging payload. Choose a strong password; you will not type it interactively.

### 2c. NoMachine license files

Copy one `.lic` file per seat into `vault\nomachine-licenses\` -- **the only
place certificates live**. The build reads the seat-to-host assignment from
`server\providers\nomachine\assets\licenses\allocated.csv` and the certificate
itself from the vault store.

Do not put a `.lic` beside `allocated.csv`: the build fails if it finds one.
An unread second copy drifts from what ships, which is how expired
certificates reached mast06 and mast07 on 2026-08-23. The build also refuses
to stage an expired certificate at all, and warns within 60 days of expiry.

If you are setting up a dev/test server that uses throwaway VMs, pass `--test-mode`
to the driver (or use the VM test orchestrator) to skip license checks. A production run
passes no such relaxation and fails loudly on a missing input.

---

## Step 3 - Create unit-registry.json

The unit registry is not checked in (there is only a template). Copy and
edit it:

```powershell
Copy-Item server\unit-registry.json.template server\unit-registry.json
```

Edit the file to describe each unit you want to manage. Minimum entry:

```json
[
  {
    "hostname": "mast01",
    "timezone": "Asia/Jerusalem",
    "maintenance_window": { "start_hour": 10, "end_hour": 16 }
  }
]
```

To restrict a unit to a subset of providers (rare; usually for debugging or
half-staged units), add a `modules` field listing the provider names you want.
Otherwise omit it and the full set discovered under `server/providers/` is
used.

```json
[
  {
    "hostname": "mast-debug-01",
    "timezone": "Asia/Jerusalem",
    "maintenance_window": { "start_hour": 0, "end_hour": 24 },
    "modules": ["cygwin", "astrometry-dependencies", "astrometry"]
  }
]
```

Notes:
- `hostname` must be the DNS-resolvable Windows computer name (`mast01` -
  `mast20`). Do not use IP addresses.
- `timezone` should be an **IANA** timezone id (e.g. `Asia/Jerusalem`; full
  list at the [IANA tz database](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones)).
  IANA ids keep the registry portable and the driver resolves them natively on either
  OS through `zoneinfo` (`server/prov/maintenance_window.py`); on Windows that needs the
  `tzdata` package, which `server/requirements.txt` pulls in. The IANA->Windows mapping
  the retired PowerShell driver carried is gone, so a raw Windows name from `tzutil /l`
  no longer resolves -- use the IANA form.
- `maintenance_window` hours are in the unit's local time. Set `start_hour: 0,
  end_hour: 24` to allow provisioning at any time (useful while setting up).
- `modules` (optional) controls which providers `build-mast.ps1` stages.
  Omitted or empty means "every provider discovered on disk", sorted by each
  provider's `module.json` `order` field. The canonical list lives at
  `server/providers/`; `Get-AllProviderModules` in
  `server/lib/mast-modules.psm1` is the helper that derives it.

---

## Step 4 - SMB share setup (elevated, once)

Run `setup-smb-share.ps1` from an elevated PowerShell. It will auto-elevate
via UAC if run without elevation.

```powershell
# From the repo root:
.\server\setup-smb-share.ps1
```

The script:
- Creates the `mast-transfer` local account (password from `vault\creds.json`)
- Creates the `staging\` and `shared\` directories if missing
- Exposes `staging\` as `\\<server>\mast-staging` (read-only for `mast-transfer`)
- Exposes `shared\` as `\\<server>\mast-shared` (read-write for `mast-transfer`)
- Sets least-privilege NTFS ACLs on both directories

The script is idempotent. Re-running it updates the password if `creds.json`
changed and recreates missing shares without affecting existing ones.

Verify:

```powershell
Get-SmbShare | Where-Object { $_.Name -like 'mast-*' } | Select Name, Path
Get-SmbShareAccess -Name mast-staging
Get-SmbShareAccess -Name mast-shared
```

Expected: two shares, access for `mast-transfer` only (no Everyone).

---

## Step 4b - NTP server setup (elevated, once)

Make this provisioning server an authoritative NTP server. MAST units frequently
cannot reach public NTP (UDP 123 blocked, or the unit is on an isolated /
link-local network with no internet route). A wrong clock then breaks the unit's
HTTPS `git clone` during provisioning (TLS cert validation) and a large skew also
destabilizes long-running WinRM sessions. The server has correct time and is
always reachable by the units it provisions, so it serves time to them.

```powershell
# Elevated PowerShell, from the repo root:
.\server\setup-ntp-server.ps1
```

The script enables the W32Time NTP server, sets `AnnounceFlags=5` (so a non-domain
standalone box will serve as a reliable source), restarts `w32time`, and opens
inbound UDP 123. Idempotent.

The unit side is automatic: the early **`timesync`** provider (order 50) discovers
this server from the active SMB connection, does a **one-time** clock correction
from it (falling back to public NTP), then leaves the unit configured for normal
public NTP for ongoing operation -- it is **not** left permanently pointed at the
provisioning server. (`client\bootstrap.ps1` also makes a best-effort public
NTP sync at bootstrap time as a redundant backstop.)

Verify:

```powershell
w32tm /query /configuration | Select-String 'NtpServer','Enabled','AnnounceFlags'
Get-NetFirewallRule -DisplayName 'MAST - NTP Server*'
```

---

## Step 5 - Firewall rules

Units connect inbound to this server on TCP 445 (SMB). If Windows Firewall is
enabled, add a rule:

```powershell
# Allow SMB inbound from the unit subnet (adjust address range):
New-NetFirewallRule -DisplayName 'MAST: SMB inbound from units' `
    -Direction Inbound -Protocol TCP -LocalPort 445 `
    -RemoteAddress '192.168.1.0/24' `
    -Action Allow -Profile Domain,Private
```

If ICMP is blocked (ping fails to units), open it:

```powershell
# Outbound ICMP echo from this server to units:
New-NetFirewallRule -DisplayName 'MAST: ICMP outbound' `
    -Direction Outbound -Protocol ICMPv4 -IcmpType 8 `
    -RemoteAddress '192.168.1.0/24' `
    -Action Allow
```

---

## Step 5b - Power and NIC settings (elevated, once)

The provisioning server must never sleep and its NIC must never idle down. Both
defaults are wrong for this role, and both were caught the hard way on 2026-08-26.

```powershell
# Never sleep, never spin down. A laptop-class provisioning server on mains
# ships with a standby timeout -- 'High performance' on labcomp2 carried a
# 600 s AC standby, which slept the host mid-session.
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change disk-timeout-ac 0

# Cover battery too: a laptop-class server whose power lead is nudged falls
# back to the DC timers, which are separate and non-zero by default.
powercfg /change standby-timeout-dc 0
powercfg /change hibernate-timeout-dc 0

# Stop the NIC that faces the units from entering low-power idle. Name the
# adapter that carries the unit traffic, not the Wi-Fi one.
Set-NetAdapterAdvancedProperty -Name 'Ethernet' -RegistryKeyword '*EEE'    -RegistryValue 0
Set-NetAdapterAdvancedProperty -Name 'Ethernet' -RegistryKeyword 'ULPMode' -RegistryValue 0
Restart-NetAdapter -Name 'Ethernet'
```

Verify:

```powershell
powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE   # AC index must be 0
Get-NetAdapterAdvancedProperty -Name 'Ethernet' |
    Where-Object RegistryKeyword -in '*EEE','ULPMode'  # both Off/Disabled
```

**Why this matters.** A sleeping server drops every session it holds; a NIC in
low-power idle makes the *first* contact after a quiet period fail. That second
effect is not cosmetic -- it corrupts address selection. `local_address_for()`
asks the OS which local address reaches a unit, and with the peer's neighbour
entry unresolved the answer is whatever interface wins the fallback, which on
this host is the Wi-Fi or VirtualBox host-only address rather than the bench
Ethernet. The run then hands that address to the unit as `-ProvAddress` and
aborts at `PREFLIGHT_UNIT_SMB_FAIL`, having built nothing.

That abort depends on the unit being unable to reach the wrong address -- here
the unit is on a guest network that cannot route to the server's campus
address, so a bad address always fails loudly. On a site where the fallback
address *is* reachable, the same defect would instead pull the payload over the
wrong (slower) interface and report success. Do not rely on the network to
catch it; see `MAST_provisioning#166`.

### Can this server be rebooted remotely?

**Check before you ever need to know.** A server that reaches the network over
enterprise Wi-Fi may have no connectivity at all until someone logs in at the
console, which makes a remote reboot a trip to the machine.

```powershell
# Auto-login: 1 means the box reaches a desktop (and its network) unattended.
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' |
    Select-Object AutoAdminLogon, DefaultUserName
netsh wlan show profiles          # 'All User Profile' = machine-scoped profile
```

Note that the profile being `All User Profile` is **not** sufficient. On
labcomp2 the `WIS_Secure` profile is machine-scoped, yet the box still had no
network for 27 minutes after a reboot on 2026-08-26 -- WPA2-Enterprise
authenticates with *user* credentials, which do not exist until a session
does. Machine-scoped profile, user-scoped credentials. With
`AutoAdminLogon=0` and no stored password, the host booted to the login screen
and stayed unreachable until someone logged in at the console.

So: on a Wi-Fi-attached server with auto-login off, treat `shutdown /r` as an
action that requires a person on site. A wired server on a machine-authenticated
network does not have this problem, which is one more reason to prefer one.

**Known not to take:** `Set-NetAdapterPowerManagement -SelectiveSuspend Disabled`
reports success on the Intel driver here and reads back `Enabled`. The effective
control is the Device Manager "allow the computer to turn off this device"
checkbox on the adapter's Power Management tab. Set it by hand.

---

## Step 6 - DNS / hostname resolution

The provisioning server must resolve `mast01`, `mast02`, etc. to the current
unit IP. Units use DHCP; the hostname is the stable identity.

**Production:** Add forward DNS A records in your site DNS (or AD) for each
`mastNN` hostname pointing at the unit's DHCP reservation. No change is needed
on the provisioning server once DNS works.

Verify:

```powershell
[System.Net.Dns]::GetHostAddresses('mast01')
```

**Dev/test (VirtualBox host-only network):** Run the helper script after each
VM boot (it updates the Windows `hosts` file):

```powershell
# Elevated - updates C:\Windows\System32\drivers\etc\hosts:
.\vm\sync-dev-unit-hosts.ps1
```

---

## Step 7 - Install the loop as a supervised service (elevated, once)

**Prerequisite -- review maintenance windows.** Each entry in
`server\unit-registry.json` carries a `maintenance_window: { start_hour, end_hour }`
and `timezone`. The driver **enforces** these: outside the window, the hash
check still runs but disruptive steps (SMB pull, execute, reboot) are skipped
with a `MAINT_SKIP` log event and a `SKIP_MAINTENANCE` row in `activity.csv`.
Confirm every unit's window reflects the operator's intent before activation. A
unit with **no** `maintenance_window` field is allowed at any time; if you need
strict gating, populate the field. For an ad-hoc fleet-wide push outside the
configured windows, invoke the driver manually with
`--maint-window-start 0 --maint-window-end 24`.

The cadence lives inside the driver (`--loop`), so there is no scheduled task to
register -- what you install is a service wrapper that keeps that one process alive.
`server\install-scheduled-task.ps1` was retired with the PowerShell driver on 2026-08-16.

```powershell
# From the repo root, elevated. Install the driver's dependencies first:
pip install -r server\requirements.txt

nssm install MAST-Provision "C:\Python312\python.exe" "server\check_and_provision.py --loop"
nssm set MAST-Provision AppDirectory "C:\repos\MAST_provisioning"
nssm set MAST-Provision AppStopMethodConsole 15000
nssm start MAST-Provision
```

`AppStopMethodConsole` matters: NSSM's stop arrives as a console Ctrl-C, which the loop
handles by finishing the current cycle and exiting cleanly. The default cadence is 1800 s
(`--interval-seconds`). On a Linux prov server the equivalent is the systemd unit in
`server/deploy/`; both are documented in **[server/deploy/README.md](../server/deploy/README.md)**.

Verify the service is running:

```powershell
nssm status MAST-Provision
Get-Service MAST-Provision
```

---

## Step 8 - First manual run

Before starting the service, run one cycle by hand and watch the log:

```powershell
# One cycle, then exit -- the same code path each loop cycle runs:
python server\check_and_provision.py

# Stream the current run log in near-real-time:
$logDir = 'C:\MAST\logs\prov\sessions'
$runDir = Get-ChildItem $logDir | Sort-Object LastWriteTime | Select-Object -Last 1
Get-Content (Join-Path $runDir.FullName ($runDir.Name + '.log')) -Wait
```

For a unit that is already up to date you will see lines like:

```
HASH_CHECK  unit=mast01 installed=<hash> built=<hash> result=UP_TO_DATE
UNIT_SKIP   unit=mast01 reason=already_current
RUN_END     units_checked=1 units_updated=0 units_failed=0 duration_s=48
```

For a unit that needs provisioning you will see `TRANSFER_START`, `EXECUTE_START`,
`PKG_OK` per module, and finally `UNIT_OK`.

If a unit is unreachable:

```
UNIT_UNREACHABLE unit=mast01 reason=winrm_port_closed
```

Check DNS, firewall, and whether WinRM is running on the unit.

---

## Monitoring

**Log locations on the provisioning server:**

| File | Content |
|------|---------|
| `C:\MAST\logs\prov\sessions\run-<ts>\run-<ts>.log` | Full structured log for each run |
| `C:\MAST\logs\prov\activity.csv` | One line per unit per run (timestamp, outcome, hash, duration) |

**Quick status check:**

```powershell
# Last 20 lines of activity:
Import-Csv C:\MAST\logs\prov\activity.csv | Select-Object -Last 20 | Format-Table

# Any failures in the last 24 hours:
Import-Csv C:\MAST\logs\prov\activity.csv |
    Where-Object { $_.outcome -notin @('OK','SKIP') -and
                   [datetime]$_.timestamp_utc -gt (Get-Date).AddDays(-1) } |
    Format-Table timestamp_utc, unit, outcome, reason
```

**Service status:**

```powershell
nssm status MAST-Provision            # SERVICE_RUNNING when the loop is alive
Get-Content C:\MAST\logs\prov\service-out.log -Tail 20   # [loop] cycle N start / end exit_code=...
```

The loop prints `[loop] cycle N start` and `[loop] cycle N end exit_code=<n>` per cycle.
`exit_code=0` means the cycle completed without a fatal error; `1` means at least one unit
failed or was unreachable. A cycle that throws is logged as `[loop] cycle N ERROR ...` and
does **not** stop the service -- check `activity.csv` for which unit it was. On Linux the
same lines land in the journal (`journalctl -u mast-provision -f`).

---

## Operational runbooks

### Add a new unit

1. Onboard the physical unit (see README "Production path").
2. Edit `server\unit-registry.json` - append a new entry with the unit hostname,
   timezone, maintenance window, and module list.
3. The next loop cycle picks up the new entry automatically.

### Force-provision a single unit now (manual)

```powershell
cd C:\repos\MAST_provisioning
python server\check_and_provision.py --only-hosts mast03 --force
```

`--force` skips the hash comparison and re-runs provisioning even if the unit
appears current. Useful after a suspected install corruption. `--only-hosts` takes a
comma-separated list.

### Pause the autonomous loop

```powershell
# Stop (the current cycle finishes first, then the process exits):
nssm stop MAST-Provision

# Resume:
nssm start MAST-Provision
```

On Linux: `sudo systemctl stop mast-provision` / `start`.

### Rotate the SMB password

1. Update `smb.pass` in `vault\creds.json`.
2. Re-run `setup-smb-share.ps1` (elevated) - it updates the `mast-transfer`
   account password and re-applies share permissions.
3. No change needed on units; they read the password from their own copy of
   `creds.json` at provisioning time.

### Update a module

1. Drop the new installer into `server\providers\<module>\assets\`.
2. Update the version reference in `server\providers\<module>\module.json`.
3. Run a build to verify: `powershell.exe -File build\build-mast.ps1 -HostName mast01`
4. Trigger a manual run (see above) to push the update.

---

## Troubleshooting

### Unit shows UNREACHABLE

Check in order:
1. DNS: `[System.Net.Dns]::GetHostAddresses('mastNN')` from the prov server.
2. Ping: `Test-Connection mastNN` (requires ICMP open on both sides).
3. WinRM port: `Test-NetConnection mastNN -Port 5985` - must show TcpTestSucceeded True.
4. Is the unit powered on and past Windows login? WinRM starts after login completes.

### TRANSFER_FAIL (robocopy error)

The unit could not connect to `\\<address>\mast-staging`.

The driver builds that UNC from **the prov server's IP address on the route to
that unit**, derived per unit and logged as `PROV_ADDR`; it does not use the
server's hostname, so the unit is not asked to resolve anything. Check `src_unc`
in `TRANSFER_START` for the address actually used.

1. Confirm the share exists on the prov server: `Get-SmbShare -Name mast-staging`.
2. From a unit, test the share manually, using the address from `PROV_ADDR`:
   ```powershell
   net use \\<address>\mast-staging /user:mast-transfer <password>
   ```
3. Check TCP 445 inbound is allowed (Step 5 above). A run now probes this from
   the unit *before* building — see `PREFLIGHT_UNIT_SMB_FAIL`.
4. Verify the `mast-transfer` password in `vault\creds.json` matches the account
   password: re-run `setup-smb-share.ps1` to synchronize them.

### PREFLIGHT_UNIT_SMB_FAIL

The unit cannot open TCP 445 to the staging address. Checked before the build, so
a run that cannot transfer does not build a payload first. Reachability only — an
authentication problem is reported later, by the pull.

1. Read the `address` in the event and confirm the unit's subnet can reach it. A
   `PROV_ADDR_FALLBACK` event just above means the driver could not derive a route
   to the unit and fell back to the server's *name*, which the unit must then
   resolve itself.
2. From the unit: `Test-NetConnection <address> -Port 445`.
3. Check the prov server's inbound 445 rule, and that nothing blocks the path
   between the two subnets.

Historic note: units used to be handed the server's hostname and resolved it
through a hand-placed `hosts` entry. Three of four had it pinned to a stale APIPA
address and every transfer failed with `net.exe` error 53; nothing in the repo
maintained those entries. They are unused now — see
`docs/decisions/2026-08-11-the-unit-is-told-an-address-not-a-name.md`.

### EXECUTE_FAIL or smoke failures

1. Open the unit's execution log:
   ```powershell
   $cred = Get-Credential   # mast / <unit password>
   Invoke-Command -ComputerName mastNN -Credential $cred -ScriptBlock {
       Get-ChildItem C:\MAST\logs\sessions | Sort-Object LastWriteTime | Select -Last 1 |
           ForEach-Object { Get-Content (Join-Path $_.FullName 'provisioning-execute.log') }
   }
   ```
2. Look for the first `[FAIL]` line - it names the failing module and the exit code.
3. For installer-level failures, check the module provider script at
   `server\providers\<module>\provide-<module>.ps1`.

### BUILD_FAIL

`build-mast.ps1` failed before the payload was staged.

1. Run the build manually and inspect the output:
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File build\build-mast.ps1 -HostName mast01
   ```
2. Common causes: missing asset file in `server\providers\<module>\assets\`,
   Git LFS pointer stub instead of real binary, or missing `vault\creds.json`.

### Lock file left from a crashed run

If `C:\MAST\execute.lock` exists on a unit after a crash:

```powershell
Invoke-Command -ComputerName mastNN -Credential $cred -ScriptBlock {
    Remove-Item C:\MAST\execute.lock -Force -ErrorAction SilentlyContinue
}
```

Then trigger a fresh run. The lock file replacement (lease-based, with TTL)
is a planned Phase 1 improvement; until then, manual removal is the recovery
procedure.

---

## Dev/test variant (VirtualBox on the same host)

This path is for a developer running the provisioning server and the unit VM on
the same Windows machine. The autonomous loop is replaced by the Python test
orchestrator `vm\run-prov-test.py`.

### One-time host prep

```powershell
# Non-elevated:
winget install Python.Python.3.12
pip install pywinrm

# Elevated (once) - adds VirtualBox + Python to Machine PATH, opens ICMP:
.\vm\admin-prep.ps1
```

Populate `vault\creds.json` as described in Step 2 (use `physics` as the unit
password for dev).

### Create the unit VM

See the README "Dev/test loop" section for the full VM creation sequence. The
short version after `vault\creds.json` exists:

```powershell
# 1. Build the autounattend ISO:
.\vm\build-autounattend-iso.ps1

# 2. Create the VM:
.\vm\vbox-create-unit.ps1 -IsoPath C:\path\to\Win11.iso `
                          -AutounattendIso .\autounattend-mast.iso

# 3. Boot and wait ~20 min for Windows install, then bootstrap the unit:
#    (Run as Administrator on the VM)
#    D:\bootstrap.cmd

# 4. Sync DNS (elevated on the host, so mastNN resolves):
.\vm\sync-dev-unit-hosts.ps1

# 5. Verify WinRM reachability:
Test-NetConnection mast01 -Port 5985
```

SMB shares are not used in the dev loop; the Python orchestrator transfers
the staging payload over HTTP. You do not need to run `setup-smb-share.ps1`
for dev cycles.

### Run a provisioning cycle

```powershell
python .\vm\run-prov-test.py --host-unit mast01 --hostname mast01
```

Cycle logs land under `C:\MAST\logs\dev\<timestamp>-cycle<N>\`.

When you are ready to test the full production flow (SMB pull, the supervised loop),
run `setup-smb-share.ps1` and install the service wrapper as described in the
production steps above. The VM unit and the real prov server use the same
`server/prov/driver.py` code path.
