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
  payload from `\\prov-server\mast-staging`.
- ICMP echo (ping) outbound to units for the reachability check.

**Software on the provisioning server:**

| Tool | Required for | Notes |
|------|--------------|-------|
| Git 2.x | Cloning the repo | winget install Git.Git |
| Git LFS | Binary assets (installers, archives) | winget install GitHub.GitLFS |
| Python 3.12 | tools/run-remote-script-winrm.py | winget install Python.Python.3.12 |
| pywinrm | Python WinRM client | pip install pywinrm |

Python and pywinrm are only needed on the provisioning server if you use
`run-remote-script-winrm.py` for ad hoc unit operations. The autonomous loop
itself (`check-and-provision.ps1`) is pure PowerShell.

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
the password set by `client\bootstrap-winrm.ps1` during unit onboarding
(default dev value is `physics`; change it for production).

`smb` is a read-only local account that `setup-smb-share.ps1` creates on this
provisioning server. Units authenticate as `mast-transfer` to pull their
staging payload. Choose a strong password; you will not type it interactively.

### 2b. tokens/mast_github.txt

Create the directory and file:

```powershell
New-Item -ItemType Directory -Force vault\tokens | Out-Null
# Paste your GitHub Personal Access Token (repo read scope) into this file:
notepad vault\tokens\mast_github.txt
```

The `mast` provisioning module uses this token to clone private MAST repos onto
units. If the `mast` module is not in your unit's module list you can skip this
for now, but autonomous runs will fail if `mast` is listed and the file is absent.

### 2c. NoMachine license files

Copy one `.lic` file per unit into `vault\nomachine-licenses\`. The build script
allocates licenses to hostnames and tracks the assignment in
`server\providers\nomachine\assets\licenses\allocated.csv`.

If you are setting up a dev/test server that uses throwaway VMs, pass
`-AllowMissingNoMachineLicense` to `check-and-provision.ps1` or the Python
test orchestrator to skip license checks.

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
    "timezone": "Israel Standard Time",
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
    "timezone": "Israel Standard Time",
    "maintenance_window": { "start_hour": 0, "end_hour": 24 },
    "modules": ["cygwin", "astrometry-dependencies", "astrometry"]
  }
]
```

Notes:
- `hostname` must be the DNS-resolvable Windows computer name (`mast01` -
  `mast20`). Do not use IP addresses.
- `timezone` must be a Windows timezone name (run `tzutil /l` for the list).
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

## Step 7 - Install the Task Scheduler job (elevated, once)

**Prerequisite -- review maintenance windows.** Each entry in
`server\unit-registry.json` carries a `maintenance_window: { start_hour, end_hour }`
and `timezone`. The driver now **enforces** these: outside the window, the hash
check still runs but disruptive steps (SMB pull, execute, reboot) are skipped
with a `MAINT_SKIP` log event and a `SKIP_MAINTENANCE` row in `activity.csv`.
Confirm every unit's window reflects the operator's intent before activation. A
unit with **no** `maintenance_window` field is allowed at any time; if you need
strict gating, populate the field. For an ad-hoc fleet-wide push outside the
configured windows, invoke the driver manually with
`-MaintenanceWindowStart 0 -MaintenanceWindowEnd 24`.

```powershell
# From the repo root, elevated:
.\server\install-scheduled-task.ps1
```

This registers the `MAST-CheckAndProvision` task to run every 30 minutes as
`SYSTEM`. The task will fire for the first time approximately 5 minutes after
registration.

Verify the task is registered:

```powershell
Get-ScheduledTask -TaskName MAST-CheckAndProvision
Get-ScheduledTask -TaskName MAST-CheckAndProvision | Get-ScheduledTaskInfo
```

---

## Step 8 - First manual run

Before waiting for the scheduler, trigger a run manually and watch the log:

```powershell
# Trigger the task (runs as SYSTEM, same as the autonomous loop):
Start-ScheduledTask -TaskName MAST-CheckAndProvision

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

**Task Scheduler status:**

```powershell
Get-ScheduledTask -TaskName MAST-CheckAndProvision | Get-ScheduledTaskInfo |
    Select LastRunTime, LastTaskResult, NextRunTime
```

`LastTaskResult 0` means the run completed without a fatal error.
`LastTaskResult 1` means at least one unit failed or was unreachable.

---

## Operational runbooks

### Add a new unit

1. Onboard the physical unit (see README "Production path").
2. Edit `server\unit-registry.json` - append a new entry with the unit hostname,
   timezone, maintenance window, and module list.
3. The next scheduled run picks up the new entry automatically.

### Force-provision a single unit now (manual)

```powershell
cd C:\repos\MAST_provisioning
powershell.exe -ExecutionPolicy Bypass -File server\check-and-provision.ps1 `
    -OnlyHosts mast03 -Force
```

`-Force` skips the hash comparison and re-runs provisioning even if the unit
appears current. Useful after a suspected install corruption.

### Pause the autonomous loop

```powershell
# Disable (task will not fire until re-enabled):
Disable-ScheduledTask -TaskName MAST-CheckAndProvision

# Re-enable:
Enable-ScheduledTask  -TaskName MAST-CheckAndProvision
```

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

The unit could not connect to `\\prov-server\mast-staging`.

1. Confirm the share exists on the prov server: `Get-SmbShare -Name mast-staging`.
2. From a unit, test the share manually:
   ```powershell
   net use \\<prov-server>\mast-staging /user:mast-transfer <password>
   ```
3. Check TCP 445 inbound is allowed (Step 5 above).
4. Verify the `mast-transfer` password in `vault\creds.json` matches the account
   password: re-run `setup-smb-share.ps1` to synchronize them.

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
#    D:\bootstrap-winrm.cmd

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

When you are ready to test the full production flow (SMB pull, Task Scheduler),
run `setup-smb-share.ps1` and `install-scheduled-task.ps1` as described in the
production steps above. The VM unit and the real prov server use the same
`check-and-provision.ps1` code path.
