# Autonomous Provisioning Design Sketch

## Goal

The provisioning server runs entirely independently: it discovers reachable MAST units on the
network, compares their installed state to the latest build, and pushes updates without any
intervention from the Mac host or a separate orchestration process.

---

## Architecture Overview

```
Provisioning Server (Windows, long-lived)
  |
  |-- Windows Task Scheduler / NSSM service
  |     runs: check-and-provision.ps1  (every N minutes)
  |
  |-- build-mast.ps1          (existing, unchanged)
  |-- check-and-provision.ps1 (new)
  |-- unit-registry.json      (list of known units + their last-known state)
  |
  +-- WinRM --> MAST Unit 1 (mast01)
  +-- WinRM --> MAST Unit 2 (mast02)
  +-- WinRM --> MAST Unit N (mastN)
```

No Mac host involvement at runtime. The Mac is only used to:
- Push git commits (new module versions, assets via lfs)
- Review logs

---

## Components

### 1. Unit Registry (`unit-registry.json`)

Tracks known units. Managed manually (add/remove entries when hardware is added/retired).

```json
[
  {
    "hostname": "mast01",
    "ip": "192.168.x.x",
    "modules": ["python", "ascom", "cygwin", "mast", "mongodb", "nomachine"]
  }
]
```

### 2. Build Manifest (`build-manifest.json`)

Written by `build-mast.ps1` after a successful build. Contains a content hash (or version tag)
for the staged payload so units can compare what they have installed against what's current.

```json
{
  "built_at": "2026-05-05T12:00:00Z",
  "git_sha": "abc1234",
  "payload_hash": "<sha256 of commands.json + all asset checksums>",
  "modules": ["python", "ascom", "cygwin", "mast", ...]
}
```

`build-mast.ps1` writes this to `staging\<hostname>\build-manifest.json` at build time.

### 3. Installed State Marker (on each unit)

After successful provisioning, `execute-mast-provisioning.ps1` writes:

```
C:\ProgramData\MAST\installed-manifest.json
```

with the same structure as `build-manifest.json`. The provisioning server compares
`payload_hash` from the build against the unit's installed hash to decide whether an
update is needed.

### 4. `check-and-provision.ps1` (new, runs on prov server)

```
for each unit in unit-registry.json:
  1. Ping / WinRM reachability check
     - unreachable → log warning, skip, continue to next unit

  2. Build latest payload for this unit
     - run build-mast.ps1 -HostName <hostname>
     - reads build-manifest.json from staging output

  3. Query unit's installed-manifest.json via WinRM
     - if payload_hash matches → log "up to date", skip

  4. Transfer staging payload to unit via WinRM
     - Invoke-Command + Copy-Item -ToSession  (same-network, no double-hop credential issue
       when prov server uses CredSSP or explicit credential forwarding)
     - alternative: unit pulls via SMB share on prov server

  5. Execute provisioning on unit
     - Invoke-Command → execute-mast-provisioning.ps1

  6. Verify smoke tests
     - check C:\ProgramData\MAST\logs\*-smoke.txt on unit

  7. Log result to C:\ProgramData\MAST\logs\autonomous-prov.log
```

### 5. Scheduling

**Option A — Windows Task Scheduler** (simplest)
- Trigger: every 30 minutes, or on a schedule aligned with expected deployment windows
- Action: `powershell.exe -File C:\mast-prov\check-and-provision.ps1`
- Run as: SYSTEM or dedicated service account with WinRM rights

**Option B — NSSM-wrapped service** (more robust)
- NSSM wraps check-and-provision.ps1 as a Windows service with restart-on-failure
- Script loops internally with `Start-Sleep`
- Easier to monitor as a service, visible in Services MMC

Recommendation: start with Task Scheduler (zero new infrastructure), migrate to NSSM if
reliability becomes an issue.

---

## Transfer: Prov Server → Unit (no Mac host)

The current orchestrator uses a Mac HTTP server to push files because the Mac is the
git-lfs source. In the autonomous model, the prov server needs the actual binaries locally.

**Solution:** on first run (or after `git pull`), the prov server fetches lfs objects
directly from the git remote:

```powershell
# On prov server, in Z:\  (the MAST_provisioning checkout)
git lfs pull
```

This requires:
- `git` installed on the provisioning server (already staged by the `mast` module)
- The prov server has network access to the git LFS storage (GitHub, internal server, etc.)
- A stored credential / deploy key for read-only LFS access

Once binaries are present on `Z:\`, they're on the Mac VirtFS mount and visible to the
prov server as local files. Transfer to units can then happen entirely via WinRM from the
prov server — no Mac host needed.

For the WinRM double-hop problem (prov → unit file copy requires credential forwarding):
- **Option A**: CredSSP on prov server (`Enable-WSManCredSSP -Role Client`)
  - Allows full credential delegation; unit receives pushes via `Copy-Item -ToSession`
- **Option B**: Unit pulls from prov server's SMB share (reverse direction, no double-hop)
  - Prov server exposes `\\prov-server\mast-staging` (already in build-mast.ps1)
  - Unit runs `net use` + `xcopy` triggered via WinRM (simpler, no CredSSP needed)
- **Option C**: Unit pulls via HTTP from prov server (same as Mac HTTP approach, but from prov)

Recommendation: Option B (unit pulls from prov SMB share) is the simplest and avoids
CredSSP complexity.

---

## Version / Drift Detection

Two levels:

1. **Payload hash** — fast check; if `installed-manifest.payload_hash == build-manifest.payload_hash`,
   the unit is up to date and no action is taken.

2. **Smoke test re-run** — optional deeper check; re-run `verify` steps on the unit even when
   hashes match, to catch runtime drift (service stopped, file deleted, etc.) without a full
   reprovisioning cycle.

---

## Observability

### Log files (all under `C:\ProgramData\MAST\logs\prov\` on the prov server)

| File | Content | Retention |
|------|---------|-----------|
| `run-<timestamp>.log` | Full per-run detail log (see below) | Keep last 30 runs |
| `activity.csv` | One-line summary per unit per run | Rolling, keep 90 days |
| `current-run.log` | Symlink / copy of the active run log; overwritten each run | Always present |
| `last-error.log` | Verbatim copy of the last run that ended in error | Overwritten on each error |

#### `run-<timestamp>.log` structure

Each run appends structured entries:

```
[2026-05-05T14:00:00Z] RUN_START  scheduler=TaskScheduler trigger=scheduled
[2026-05-05T14:00:01Z] BUILD_START  unit=mast01 git_sha=abc1234
[2026-05-05T14:00:45Z] BUILD_OK     unit=mast01 duration_s=44 payload_hash=a3f9...
[2026-05-05T14:00:45Z] HASH_CHECK   unit=mast01 installed=a3f9... built=a3f9... result=UP_TO_DATE
[2026-05-05T14:00:45Z] UNIT_SKIP    unit=mast01 reason=already_current
[2026-05-05T14:00:45Z] BUILD_START  unit=mast02 git_sha=abc1234
[2026-05-05T14:01:30Z] BUILD_OK     unit=mast02 duration_s=45 payload_hash=b7e2...
[2026-05-05T14:01:30Z] HASH_CHECK   unit=mast02 installed=<none> built=b7e2... result=NEEDS_UPDATE
[2026-05-05T14:01:31Z] TRANSFER_START  unit=mast02 files=41 bytes=1362534400
[2026-05-05T14:09:15Z] TRANSFER_OK     unit=mast02 duration_s=464
[2026-05-05T14:09:16Z] EXECUTE_START   unit=mast02
[2026-05-05T14:55:00Z] EXECUTE_OK      unit=mast02 duration_s=2744 exit_code=0
[2026-05-05T14:55:01Z] SMOKE_START     unit=mast02
[2026-05-05T14:55:05Z] SMOKE_RESULT    unit=mast02 module=python status=OK
[2026-05-05T14:55:05Z] SMOKE_RESULT    unit=mast02 module=ascom  status=FAIL reason=smoke_file_missing
[2026-05-05T14:55:05Z] UNIT_FAIL       unit=mast02 reason=smoke_failures modules=ascom
[2026-05-05T14:55:05Z] RUN_END  units_checked=2 units_updated=1 units_failed=1 duration_s=2704
```

Key design rules:
- Every event has an ISO 8601 UTC timestamp and a fixed `EVENT_TYPE` token so logs are
  `grep`-able and machine-parseable.
- `EXECUTE_START` / `EXECUTE_OK` / `EXECUTE_FAIL` bracket the long-running provisioning step
  so you can see exactly where time is spent.
- `TRANSFER_START` logs the total file count and byte count so stalls are immediately visible.
- Each `SMOKE_RESULT` line names the module and the failure reason (missing file, wrong content,
  service not running, etc.) — not just a pass/fail count.
- `UNIT_SKIP` / `UNIT_FAIL` / `UNIT_OK` give a machine-readable per-unit outcome.
- On unexpected exceptions, a `EXCEPTION` event is written with the full stack trace before
  the run aborts.

#### `activity.csv` schema

```
timestamp_utc, run_id, unit, outcome, reason, duration_s, payload_hash, git_sha
2026-05-05T14:55:05Z, run-20260505-140000, mast01, SKIP,    already_current, 1,    a3f9..., abc1234
2026-05-05T14:55:05Z, run-20260505-140000, mast02, FAIL,    smoke:ascom,     2704, b7e2..., abc1234
```

`outcome` is one of: `OK`, `SKIP`, `FAIL`, `UNREACHABLE`, `BUILD_FAIL`, `TRANSFER_FAIL`,
`EXECUTE_FAIL`. This makes it easy to `grep` or import into a spreadsheet for trend analysis.

### Progress visibility during long operations

Long-running phases (transfer, execute) write heartbeat lines every 30 seconds:

```
[2026-05-05T14:09:00Z] TRANSFER_PROGRESS  unit=mast02 files_done=28/41 bytes_done=950000000/1362534400
[2026-05-05T14:30:00Z] EXECUTE_PROGRESS   unit=mast02 elapsed_s=1244 last_module=mongodb
```

`execute-mast-provisioning.ps1` writes its own per-module progress to a sidecar file
`C:\ProgramData\MAST\logs\prov\execute-progress.txt` on the unit, which the prov server
polls via WinRM during execution and relays into the run log.

### Windows Event Log integration

Each `RUN_END` writes a single Windows Event Log entry (source: `MAST-Provisioning`,
Event ID 1000=OK, 1001=partial failure, 1002=run error). This lets any existing monitoring
agent (Zabbix, Datadog, etc.) pick up provisioning outcomes without parsing log files.

### Alerting

`check-and-provision.ps1` accepts an optional `-AlertEmail` parameter. If set, it sends a
plain-text summary email via `Send-MailMessage` on any run where one or more units ended
`FAIL` or `UNREACHABLE`. Subject line: `[MAST] Provisioning alert: mast02 FAIL (smoke:ascom)`.
No email on all-OK or all-SKIP runs.

---

## Unit Availability During Maintenance

When a unit enters a maintenance window (provisioning, Windows Update, or reboot), it must be
marked unavailable to the MAST system so the scheduler does not assign observations to it.

### Mechanism

`check-and-provision.ps1` signals availability changes by writing a status file on the unit:

```
C:\ProgramData\MAST\status\availability.json
```

```json
{
  "available": false,
  "reason": "maintenance",
  "since_utc": "2026-05-06T11:00:00Z",
  "expected_return_utc": "2026-05-06T16:00:00Z"
}
```

The MAST scheduler reads this file (via the same WinRM channel it uses for everything else)
before assigning any observation job. A unit is only eligible for scheduling when
`available == true`.

### Lifecycle

| Event | `available` | `reason` |
|-------|-------------|----------|
| Maintenance window starts | `false` | `"maintenance"` |
| Provisioning or update running | `false` | `"provisioning"` or `"windows_update"` |
| Reboot in progress | `false` | `"rebooting"` |
| Post-reboot smoke tests pass | `true` | _(field removed)_ |
| Smoke tests fail | `false` | `"smoke_failure"` |

`expected_return_utc` is set to the end of the maintenance window when entering; it is omitted
for unplanned unavailability (e.g. `"smoke_failure"`).

### Integration point

The MAST scheduler should treat a missing or unreadable `availability.json` as `available:
false` (fail-safe). The file is written atomically (write to `.tmp`, rename) to avoid a
partial-read race during status transitions.

### Log events

```
[2026-05-06T11:00:00Z] AVAIL_SET  unit=mast01 available=false reason=maintenance
[2026-05-06T11:07:10Z] AVAIL_SET  unit=mast01 available=true  reason=maintenance_complete
[2026-05-06T11:05:00Z] AVAIL_SET  unit=mast01 available=false reason=smoke_failure
```

---

## Windows Updates and Scheduled Reboots

### Principle: daylight hours only

MAST units are observatory machines. Sky observations run at night. All disruptive maintenance
— Windows Updates, reboots, and any sysadmin tasks that take the unit offline — must be
confined to **daylight hours** (nominally 10:00–16:00 local site time), when no science data
can be collected regardless. The provisioning scheduler must enforce this window.

`check-and-provision.ps1` accepts `-MaintenanceWindowStart` and `-MaintenanceWindowEnd`
parameters (24-hour local time, e.g. `10` and `16`). Any run that starts outside the window
skips the update and reboot steps and logs `MAINT_SKIP reason=outside_window`.

### Disable automatic updates during initial provisioning

Before running `execute-mast-provisioning.ps1`, Windows Update must be prevented from
installing updates and rebooting mid-run. This is a required step in `prepare-mast-client.ps1`
(the one-time unit setup script that runs before the provisioning pipeline):

```powershell
# Disable automatic update installation during provisioning.
# AUOptions = 1 = never check (fully suppressed during setup).
# Restored to AUOptions = 3 (download-only) after provisioning completes.
$auPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $auPath -Force | Out-Null
Set-ItemProperty -Path $auPath -Name NoAutoUpdate   -Value 1 -Type DWord
Set-ItemProperty -Path $auPath -Name AUOptions      -Value 1 -Type DWord
Set-ItemProperty -Path $auPath -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord
# Stop and disable the Windows Update service for the duration of provisioning
Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Set-Service  wuauserv -StartupType Disabled
```

After provisioning completes successfully, `execute-mast-provisioning.ps1` (or a post-provision
step in `check-and-provision.ps1`) restores the unit to the managed download-only policy:

```powershell
# Restore to download-only; installation controlled by maintenance window.
Set-ItemProperty -Path $auPath -Name AUOptions -Value 3 -Type DWord
Remove-ItemProperty -Path $auPath -Name NoAutoUpdate -ErrorAction SilentlyContinue
Set-Service  wuauserv -StartupType Automatic
Start-Service wuauserv
```

### Windows Update policy (steady-state)

Configure each unit via Group Policy or registry to **download but not install** updates
automatically. Installation is triggered by `check-and-provision.ps1` during the maintenance
window, so the provisioning server controls timing — not Windows Update's own scheduler.

```powershell
# Disable automatic install; allow download only (AUOptions = 3)
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' `
    -Name AUOptions -Value 3 -Type DWord
```

### Update + reboot sequence (inside maintenance window only)

`check-and-provision.ps1` runs this sequence after all units have been provisioned:

```
for each unit in unit-registry.json (inside maintenance window):
  1. Check for pending Windows Updates via PSWindowsUpdate or WUA COM API
     - none pending → log WUPDATE_SKIP reason=no_pending, skip
  2. Install pending updates via WinRM:
       Invoke-Command → Install-WindowsUpdate -AcceptAll -AutoReboot:$false
     - Log each KB number installed to activity.csv
  3. Check if reboot is required (PendingReboot registry key):
     HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending
     HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations
  4. If reboot required:
     a. Check time: if < 30 min before MaintenanceWindowEnd, defer to next day
     b. Log REBOOT_START unit=<name> reason=windows_update
     c. Invoke-Command → Restart-Computer -Force
     d. Wait for WinRM to come back (up to 10 min)
     e. Log REBOOT_OK unit=<name> elapsed_s=<n>
  5. Re-run smoke tests post-reboot to confirm unit is healthy
```

### PSWindowsUpdate module

`check-and-provision.ps1` depends on the
[PSWindowsUpdate](https://www.powershellgallery.com/packages/PSWindowsUpdate) module on each
unit. Installed once during initial provisioning:

```powershell
Install-Module PSWindowsUpdate -Force -Scope AllUsers
```

Add this to `execute-mast-provisioning.ps1` or as a dedicated `windowsupdate` module in the
provisioning pipeline.

### Log events

```
[2026-05-06T11:00:00Z] MAINT_START     unit=mast01 window=10:00-16:00
[2026-05-06T11:00:01Z] WUPDATE_CHECK   unit=mast01 pending=3
[2026-05-06T11:04:30Z] WUPDATE_OK      unit=mast01 installed=3 kbs=KB5034765,KB5035942,KB5036210
[2026-05-06T11:04:31Z] REBOOT_REQUIRED unit=mast01
[2026-05-06T11:04:32Z] REBOOT_START    unit=mast01 reason=windows_update
[2026-05-06T11:06:45Z] REBOOT_OK       unit=mast01 elapsed_s=133
[2026-05-06T11:07:10Z] SMOKE_RESULT    unit=mast01 module=python status=OK
[2026-05-06T11:07:10Z] UNIT_OK         unit=mast01
[2026-05-06T22:30:00Z] MAINT_SKIP      unit=mast02 reason=outside_window current=22:30 window=10:00-16:00
```

### Deferred reboots

If a reboot is pending but there is less than 30 minutes left in the maintenance window, the
reboot is deferred. The unit is marked `REBOOT_DEFERRED` in `activity.csv` and retried on the
next day's maintenance run. The unit remains operational (running the old kernel/drivers) until
the next window — acceptable for observatory use since the risk of deferring by ~18 hours is
low.

### Summary

| Task | Runs when |
|------|-----------|
| MAST provisioning (software install) | Inside maintenance window |
| Windows Update check + install | Inside maintenance window |
| Reboot (if required) | Inside maintenance window, ≥30 min remaining |
| Smoke test re-run post-reboot | Immediately after reboot completes |
| All other `check-and-provision` logic | Any time (hash check, skip if current) |

The maintenance window parameters are stored in `unit-registry.json` per unit so sites at
different longitudes (and therefore different local sunrise/sunset times) can each have their
own window:

```json
{
  "hostname": "mast01",
  "ip": "192.168.x.x",
  "timezone": "America/Los_Angeles",
  "maintenance_window": { "start_hour": 10, "end_hour": 16 },
  "modules": ["python", "ascom", "cygwin", "mast", "mongodb", "nomachine"]
}
```

---

## Unit Onboarding: One-Shot Bootstrap Script

### Goal

A single script — `client/onboard-mast-unit.ps1` — handles everything from a bare Windows IoT
install through to full autonomous operation. An operator runs it once on the physical machine
(or it is injected via answer file for VMs). When it exits successfully, the unit is:

- Named, networked, and WinRM-reachable
- Fully provisioned (all MAST software installed and smoke-tested)
- Registered with the provisioning server's unit registry
- Running the autonomous `check-and-provision` scheduled task

No further Mac or operator involvement is needed.

### Script Stages

```
onboard-mast-unit.ps1
  │
  ├── Stage 0  PREFLIGHT       Verify: admin rights, network reachability, vault creds accessible
  ├── Stage 1  BOOTSTRAP       Enable WinRM (HTTP), set hostname, create mast account
  ├── Stage 2  PREPARE         Harden WinRM (HTTPS), suppress Windows Update, set static IP
  ├── Stage 3  PROVISION       Run full MAST provisioning (build → transfer → execute → smoke)
  ├── Stage 4  REGISTER        Add unit to unit-registry.json on prov server
  └── Stage 5  HANDOFF         Install and enable check-and-provision scheduled task; write
                               availability.json {available: true}
```

Each stage logs a `STAGE_START` / `STAGE_OK` / `STAGE_FAIL` bracket so the operator can see
exactly where a failure occurred and re-run from that stage with `-ResumeFrom <stage>`.

### Observability

Every action the script takes is written to a local log **and** mirrored to the provisioning
server from Stage 2 onward (once WinRM to the prov server is available):

#### Local log (always present, even if network fails)

```
C:\ProgramData\MAST\logs\onboarding.log
```

Structured entries — same format as the autonomous pipeline logs:

```
[2026-05-06T11:00:00Z] STAGE_START    stage=0 name=PREFLIGHT
[2026-05-06T11:00:01Z] CHECK_OK       check=admin_rights
[2026-05-06T11:00:01Z] CHECK_OK       check=network unit=mast01 prov_ip=192.168.64.10
[2026-05-06T11:00:01Z] STAGE_OK       stage=0 name=PREFLIGHT duration_s=1
[2026-05-06T11:00:02Z] STAGE_START    stage=1 name=BOOTSTRAP
[2026-05-06T11:00:03Z] ACTION         step=enable_winrm
[2026-05-06T11:00:05Z] ACTION_OK      step=enable_winrm
[2026-05-06T11:00:05Z] ACTION         step=set_hostname value=mast01
[2026-05-06T11:00:06Z] ACTION_OK      step=set_hostname
[2026-05-06T11:00:06Z] ACTION         step=create_mast_account
[2026-05-06T11:00:07Z] ACTION_OK      step=create_mast_account
[2026-05-06T11:00:07Z] STAGE_OK       stage=1 name=BOOTSTRAP duration_s=5
...
[2026-05-06T13:45:00Z] STAGE_OK       stage=3 name=PROVISION duration_s=9298
[2026-05-06T13:45:01Z] STAGE_START    stage=4 name=REGISTER
[2026-05-06T13:45:02Z] ACTION_OK      step=register_unit prov=192.168.64.10 unit=mast01
[2026-05-06T13:45:02Z] STAGE_OK       stage=4 name=REGISTER duration_s=1
[2026-05-06T13:45:03Z] STAGE_START    stage=5 name=HANDOFF
[2026-05-06T13:45:05Z] ACTION_OK      step=install_scheduled_task
[2026-05-06T13:45:05Z] ACTION_OK      step=write_availability available=true
[2026-05-06T13:45:05Z] STAGE_OK       stage=5 name=HANDOFF duration_s=2
[2026-05-06T13:45:05Z] ONBOARD_OK     unit=mast01 total_duration_s=9305
```

#### Remote mirror (prov server, Stage 2+)

The script ships each log line to the prov server via WinRM as it is written, so the operator
can monitor progress from the Mac without looking at the VM console:

```powershell
# On Mac — tail the remote onboarding log while it runs:
Invoke-Command -ComputerName 192.168.64.10 -Credential $provCred -ScriptBlock {
    Get-Content 'C:\ProgramData\MAST\logs\onboarding\mast01.log' -Wait
}
```

The prov server stores per-unit onboarding logs under:
```
C:\ProgramData\MAST\logs\onboarding\<hostname>.log
```

#### On-screen progress (operator console)

The script writes a compact one-line status to the console for each action:

```
[11:00:01]  Stage 0 PREFLIGHT          ✓ admin_rights
[11:00:01]  Stage 0 PREFLIGHT          ✓ network (prov reachable)
[11:00:05]  Stage 1 BOOTSTRAP          ✓ WinRM enabled
[11:00:06]  Stage 1 BOOTSTRAP          ✓ hostname → mast01
...
[13:45:05]  Stage 5 HANDOFF            ✓ scheduled task installed
[13:45:05]  ── ONBOARD COMPLETE  mast01  2h 34m 5s ──
```

If a stage fails, the console shows the failing action, the error, and the resume command:

```
[11:02:14]  Stage 2 PREPARE            ✗ set_static_ip  →  Adapter not found
            To resume: .\onboard-mast-unit.ps1 -HostName mast01 -ResumeFrom 2
```

### Parameters

```powershell
.\onboard-mast-unit.ps1 `
    -HostName    mast01          `  # required
    -ProvServer  192.168.64.10   `  # IP of provisioning server
    -StaticIP    192.168.64.20   `  # optional; omit to keep DHCP
    -Modules     python,ascom,mast `  # optional; defaults to all
    -ResumeFrom  0               `  # stage to resume from (0 = start fresh)
    -DryRun                         # log actions without executing them
```

### Failure and Resume

Each stage writes a checkpoint file on completion:

```
C:\ProgramData\MAST\onboarding-checkpoint.json
{"unit": "mast01", "last_completed_stage": 2, "timestamp_utc": "..."}
```

`-ResumeFrom` defaults to the last completed stage + 1, so re-running the script after a
failure automatically continues from where it left off. Stages are idempotent — running Stage 1
twice on an already-bootstrapped machine is safe.

### Handoff contract

After Stage 5 completes, control passes entirely to the provisioning server:

- `check-and-provision.ps1` runs on the prov server every 30 minutes via Task Scheduler
- The unit's `availability.json` is `{available: true}`
- The unit's `installed-manifest.json` records the provisioned payload hash
- Any future software update or re-provisioning is triggered autonomously — no operator needed

### Dev/test VM path

For VMs built by `run-prov-test.py --build-image`, Stages 1–2 are handled by the answer file
(WinRM is enabled and the hostname is set before the OS is handed off). The orchestrator runs
`onboard-mast-unit.ps1 -ResumeFrom 3` via WinRM after first boot, picking up at the
provisioning stage.

### Physical unit path

1. Copy `client/onboard-mast-unit.ps1` to a USB drive along with `vault/utm-creds.json`.
2. On the unit: open an admin PowerShell and run:
   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process -Force
   .\onboard-mast-unit.ps1 -HostName mast01 -ProvServer 192.168.64.10 -StaticIP 192.168.64.20
   ```
3. Walk away. Monitor from the Mac via the remote log tail shown above.
4. Script exits with `ONBOARD_OK` — unit is live and autonomous.

---

## Rollout Steps

1. Add `payload_hash` generation to `build-mast.ps1` → write `build-manifest.json`
2. Add `installed-manifest.json` write to `execute-mast-provisioning.ps1`
3. Write `check-and-provision.ps1` using the loop above
4. Ensure `git lfs pull` works on the prov server (deploy key or stored credential)
5. Set up Task Scheduler trigger on the prov server
6. Run one manual dry-run (`check-and-provision.ps1 -DryRun`) to validate discovery + hash logic
7. Enable live runs; monitor CSV log for a week before treating as production

---

## Open Questions

- **Git credential on prov server**: how are lfs credentials stored securely? (Windows
  Credential Manager, deploy key, PAT in vault?)
- **Network discovery vs static registry**: should units self-register (e.g., on boot send
  a UDP beacon), or is the static `unit-registry.json` sufficient for the expected unit count?
- **Rollback**: if provisioning fails on a unit, what is the recovery path? (Re-run from
  last known-good snapshot, or just retry next cycle?)
- **Concurrency**: provision units sequentially or in parallel? Parallel is faster but
  harder to debug; sequential is safer for a small fleet.
