# Autonomous Provisioning Design Sketch

> **Document status:** This document is organized into three delivery phases plus a
> **Foundation** section for building blocks that are already implemented. Sections marked
> **[DONE]** reflect the current codebase state. **[PARTIAL]** means scaffolding exists
> but the feature is not complete. Unmarked items under each phase are the remaining work
> to converge toward.
>
> **Important:** The codebase currently has scripts that can perform provisioning steps
> when invoked manually. The driver now enforces maintenance windows and emits a
> `module_versions` map in `build-manifest.json` -- the last gating Foundation items
> for unattended operation. Activating the scheduled task on the prov server is the
> remaining operator step before the autonomous loop is live. Phase 1 driver
> self-monitoring (heartbeat + `last-run.json`), lease replacement, and the remaining
> test-mode exceptions are the next workstreams.

## Status key

- **[DONE]** - Implemented in the current codebase and verified by code review.
- **[PARTIAL]** - Scaffolding or partial logic exists; gaps noted inline.
- *(no marker)* - Not yet implemented; target behavior described below.

## Phase overview

| Phase | Theme | Key deliverables |
|-------|-------|-----------------|
| **Foundation** | Already shipped | build+hash pipeline, onboarding script, WinRM tooling, unit registry |
| **Phase 1** | Core correctness | Lock replacement, non-elevated prov server, test-mode hardening, maintenance window enforcement |
| **Phase 2** | Operations resilience | Resource lifecycle, module uninstall/reinstall, version pinning + rollback, Windows Update, SSH server |
| **Phase 3** | Observability | Prometheus scrape targets, central Grafana dashboard, structured log tokens, alerting |

---

## Foundation (building blocks implemented)

### Target outcome

The provisioning server runs **entirely** independently: discovers reachable MAST units on
the network, compares their installed state to the latest build, and pushes updates without
intervention from a separate orchestration process. **This is the end goal, not the current
state.** See Phase 1 for the work needed to get there.

**Identity and addressing [DONE]:** Each unit is identified **only** by its configured Windows
hostname (for example `mast01`). The machine **must** be allowed to use **DHCP** for IPv4;
operators and automation discover units **by name** (DNS, reverse DNS, or a managed hosts
file), not by pinning a fixed address in scripts or `unit-registry.json`. Do not treat an
IP as the long-lived identity of a unit.

**Operator SSH access:** Each fleet unit must have an **SSH server installed, configured,
and running** in steady state so authorized staff can **remote in interactively** when
needed. This is **complementary** to WinRM used for provisioning automation; see
**Fleet SSH server (operator remote access)** in Phase 2.

---

### Development lab: hostname resolution (simulate internal DNS) **[DONE]**

Production units resolve each other and are reached by the provisioning server using
**corporate or site DNS** (forward records for `mast01` ... `mast20`). No fixed IP appears
in `unit-registry.json`.

On a **developer PC** running VirtualBox with **host-only DHCP**, the guest address changes
and hostnames do not resolve until something provides the same name-to-address mapping DNS
would supply.

**Automated lab mapping (this repo):** run **`vm/sync-dev-unit-hosts.ps1`** in an
**elevated** PowerShell on the **Windows host** (once after the VM has DHCP, or whenever
the guest IP changes). The script:

- discovers the guest IPv4 (VirtualBox Guest Additions property when present, otherwise
  NIC1 MAC vs `Get-NetNeighbor` on the host-only subnet, else a single VirtualBox-style
  MAC on that subnet),
- inserts a **marked block** into `%SystemRoot%\System32\drivers\etc\hosts` so
  `[System.Net.Dns]::GetHostAddresses('mast01')` matches production behavior,
- keeps a timestamped backup of `hosts`.

This is **lab-only**. Do **not** rely on it on the **production provisioning server** when
real DNS already resolves `mastNN`. Operators should never hand-edit `hosts` for each DHCP
renewal in automation; the script is the supported dev substitute.

**Integration hint:** after `vbox-recreate-unit.ps1` reports WinRM up, run
`sync-dev-unit-hosts.ps1` so `check-and-provision.ps1`, `run-prov-test.py`, and
`Invoke-Command -ComputerName mast01` all see the same hostname contract as in the field.

---

### Architecture Overview (target)

```
Provisioning Server (Windows, long-lived)
  |
  |-- Windows Task Scheduler / NSSM service
  |     runs: check-and-provision.ps1  (every N minutes)
  |
  |-- build-mast.ps1          (existing, unchanged)
  |-- check-and-provision.ps1  (autonomous loop driver)
  |-- unit-registry.json      (discovery: units to contact -- no cached per-unit installed state)
  |
  +-- WinRM --> MAST Unit 1 (mast01)
  +-- WinRM --> MAST Unit 2 (mast02)
  +-- WinRM --> MAST Unit N (mastN)
  |
  +-- SSH (optional path for operators) --> same units when enabled
```

---

### Single provisioning server **[DONE]**

**Requirement:** The fleet uses **exactly one** long-lived Windows provisioning machine.
There is no multi-master orchestration problem to solve at the control-plane layer;
autonomous design, credentials, logging, and operational runbooks should assume **one**
authoritative host runs the scheduled provisioning loop (`check-and-provision.ps1` or its
successor). Other machines may still push git changes or view logs, but **only this
provisioning server** drives unit updates on cadence.

---

### Components

#### 1. Unit Registry (`unit-registry.json`) **[DONE]**

Tracks known units. Managed manually (add/remove entries when hardware is added/retired).
Does not store per-unit installed manifests or probe results -- see **Unit provisioning
manifest** below.

```json
[
  {
    "hostname": "mast01",
    "timezone": "America/Los_Angeles",
    "maintenance_window": { "start_hour": 10, "end_hour": 16 },
    "modules": ["python", "ascom", "cygwin", "mast", "mongodb", "nomachine"]
  }
]
```

The per-unit `modules` array is the seed for future profile-based provisioning: different
units can already receive different module sets by editing their registry entry. See
**Unit profiles (future hardware variation)** in Phase 2 for the fuller design.

#### 2. Build Manifest (`build-manifest.json`) **[DONE]**

Written by `build-mast.ps1` after a successful build. Contains a content hash for the
staged payload so units can compare what they have installed against what's current,
and a `module_versions` map so the fleet can answer "what version of python is on
mast03?" without remoting in.

**Schema** (as written by `build-mast.ps1`):

```json
{
  "built_at": "2026-05-16T16:24:00Z",
  "git_sha": "6da70693a4ee557d22fcc02099fb3f47a08fab36",
  "payload_hash": "<sha256>",
  "hostname": "mast01",
  "modules": ["ascom", "chrome", "cygwin", "..."],
  "module_versions": {
    "ascom":          "7.1.0",
    "chrome":         "stable",
    "cygwin":         "cygwin64-snapshot",
    "diagnostics":    "builtin",
    "git":            "2.52.0",
    "mast":           "6da70693a4ee557d22fcc02099fb3f47a08fab36",
    "mongodb-client": "mongosh-2.2.6/tools-100.9.4",
    "nomachine":      "9.0.188",
    "python":         "3.12.0",
    "sysinternals":   "rolling",
    "...": "..."
  }
}
```

`build-mast.ps1` writes this to `staging\<hostname>\01-provisioning\build-manifest.json`
at build time. The `module_versions` map is aggregated from the `version` field in each
provider's `module.json`. A missing or whitespace `version` is a build error (`throw
"module.json missing 'version' for module '<name>'"`) -- explicit failure beats silent
omission. The literal string `"git"` is substituted with the current `$gitSha` at
aggregate time, so source-tracked modules (e.g. `mast`) report a meaningful hash.
Modules with no external versioned payload use `"builtin"` (diagnostics) or `"rolling"`
(sysinternals); composite installers use slash-joined strings (e.g.
`"mongosh-2.2.6/tools-100.9.4"`).

#### 3. Installed / effective state (on each unit) **[PARTIAL]**

`execute-mast-provisioning.ps1` writes `installed-manifest.json` after a successful run,
copying `build-manifest.json` with an added `installed_at` timestamp. This satisfies the
hash comparison used by `check-and-provision.ps1` for drift detection.

**Remaining gap:** The requirements call for a preference toward **computed** manifests
(inspecting the live filesystem and service state rather than trusting the written file).
The static file is acceptable as an audit artifact today; the inspection-based probe is a
Phase 1 stretch goal. The provisioning server compares `build-manifest.payload_hash` to
the effective hash reported by the unit to decide whether an update is needed.

#### 4. `check-and-provision.ps1` (prov server driver) **[PARTIAL]**

The script implements the full provisioning control flow using WinRM Basic HTTP (port 5985,
no `TrustedHosts` elevation required) and SMB pull for payload transfer. The workflow runs
end-to-end against a VirtualBox unit. It writes `activity.csv` with the documented schema
and manages `availability.json` on the unit. **Maintenance window enforcement is
implemented** (see the Phase 1 section of the same name): outside a unit's
`maintenance_window`, the hash check still runs but disruptive steps are skipped with a
`MAINT_SKIP` event and a `SKIP_MAINTENANCE` activity row.

**Remaining gap:** the task scheduler job (see item 5) is not yet activated on the
production server, and the Phase 1 driver self-monitoring work (mid-cycle heartbeat +
`last-run.json`) is outstanding. The intended control flow is:

```
for each unit in unit-registry.json:
  1. Ping / WinRM reachability check
     - unreachable -> log warning, skip, continue to next unit

  2. Build latest payload for this unit
     - run build-mast.ps1 -HostName <hostname>
     - reads build-manifest.json from staging output

  3. Query the unit's installed-manifest.json via WinRM
     - if payload_hash matches -> log "up to date", skip

  4. Transfer staging payload to unit via SMB pull
     - Invoke-Command -> net use \\prov-server\mast-staging + robocopy

  5. Execute provisioning on unit
     - Invoke-Command -> execute-mast-provisioning.ps1

  6. Verify smoke tests
     - check C:\MAST\logs\smoke\*-smoke.txt on unit

  7. Log result (activity.csv + session log)
```

#### 5. Scheduling **[PARTIAL]**

`server/install-scheduled-task.ps1` exists and can register a Task Scheduler job to run
`check-and-provision.ps1` every 30 minutes under SYSTEM. **Activation prerequisites are
now met** -- maintenance window enforcement landed (the previously gating Foundation
work), so an unattended fire on a 30-minute cadence will respect each unit's window.
The task has **not** yet been installed on the provisioning server; that is a one-time
operator step (elevated `.\server\install-scheduled-task.ps1`, documented in
`docs/provisioning-server-setup.md` Step 7). Phase 1 driver self-monitoring (heartbeat
+ `last-run.json`) can land before or after this activation -- it is not gating.

---

### Transfer: Prov Server -> Unit **[DONE]**

`check-and-provision.ps1` uses **SMB pull**: the unit connects to
`\\<prov-server>\mast-staging` and copies its payload using `net use` + `robocopy` via a
short WinRM command sent by the orchestrator. `Copy-Item -ToSession` (WinRM push) is no
longer used. No credential forwarding or CredSSP is required on the provisioning server
side.

**Credential handling:** the SMB share requires authenticated access. The provisioning
service account credentials (or a dedicated read-only share account) must be stored
securely on the unit side or passed at call time via the WinRM command. This avoids the
double-hop problem and keeps the prov server's WinRM client unprivileged.

**Required setup on prov server:**
- SMB share `mast-staging` pointing at the staging output directory (created by
  `build-mast.ps1`).
- Share and NTFS permissions scoped to the unit service account or a dedicated
  `mast-transfer` account.
- Firewall rule allowing TCP 445 inbound from the unit subnet.

---

### Version / Drift Detection **[PARTIAL]**

The logic is present in `check-and-provision.ps1` (hash compare at lines ~234-294)
and verified end-to-end via `vm/run-prov-test.py`. It is exercised on every manual
driver invocation today; it becomes a continuous fleet guarantee once the scheduled
task is activated on the prov server (Components #5 above). No driver-side gaps remain
for drift detection itself.

Two levels:

1. **Payload hash** -- fast check; if the unit's `installed-manifest.payload_hash` equals
   `build-manifest.payload_hash`, the unit is up to date and no action is taken.

2. **Smoke test re-run** -- optional deeper check; re-run `verify` steps on the unit even
   when hashes match, to catch runtime drift (service stopped, file deleted, etc.) without
   a full reprovisioning cycle.

---

### Unit Onboarding: One-Shot Bootstrap Script **[PARTIAL]**

`client/onboard-mast-unit.ps1` handles everything from a bare Windows IoT install through
to the point where provisioning can be triggered. An operator runs it once on the physical
machine (or it is injected via answer file for VMs). When that pipeline is complete, the
unit should be:

- Named, networked, and WinRM-reachable
- Fully provisioned (all MAST software installed and smoke-tested)
- Registered with the provisioning server's unit registry
- Ready to be picked up by the autonomous `check-and-provision` loop once Phase 1 is complete

The script has not been validated end-to-end against a physical unit. Stage 5 (HANDOFF)
installs the scheduled task and writes `availability.json`, but the autonomous loop it
hands off to is not yet operational.

**Script stages:**

```
onboard-mast-unit.ps1
  |
  +-- Stage 0  PREFLIGHT       Verify: admin rights, network reachability, vault creds accessible
  +-- Stage 1  BOOTSTRAP       Enable WinRM (HTTP), set hostname, create mast account
  +-- Stage 2  PREPARE         Harden WinRM (HTTPS), suppress Windows Update
  +-- Stage 3  PROVISION       Run full MAST provisioning (build -> transfer -> execute -> smoke)
  +-- Stage 4  REGISTER        Add unit to unit-registry.json on prov server
  +-- Stage 5  HANDOFF         Install and enable check-and-provision scheduled task;
                               write availability.json {available: true}
```

Each stage logs `STAGE_START` / `STAGE_OK` / `STAGE_FAIL` brackets. A checkpoint file at
`C:\ProgramData\MAST\onboarding-checkpoint.json` tracks the last completed stage so
`-ResumeFrom` can restart from a failure without re-running earlier stages.

**Parameters:**

```powershell
.\onboard-mast-unit.ps1 `
    -HostName    mast01          `  # required
    -ProvServer  192.168.64.10   `  # IP or DNS name of provisioning server
    -Modules     python,ascom,mast `
    -ResumeFrom  0               `  # stage to resume from (0 = start fresh)
    -DryRun                         # log actions without executing them
```

**Dev/test VM path:** Stages 1-2 handled by the answer file (WinRM enabled, hostname set
before OS handoff). Orchestrator runs `onboard-mast-unit.ps1 -ResumeFrom 3` via WinRM
after first boot.

**Physical unit path:**
1. Copy `client/onboard-mast-unit.ps1` to a USB drive with `vault/utm-creds.json`.
2. On the unit: open an admin PowerShell and run:
   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process -Force
   .\onboard-mast-unit.ps1 -HostName mast01 -ProvServer 192.168.64.10
   ```
3. Monitor remotely via:
   ```powershell
   Invoke-Command -ComputerName 192.168.64.10 -Credential $provCred -ScriptBlock {
       Get-Content 'C:\MAST\logs\onboarding\mast01.log' -Wait
   }
   ```

---

### Unit Availability During Maintenance **[DONE]**

Stage 5 of `onboard-mast-unit.ps1` writes `availability.json` with `available: true` on
handoff. `check-and-provision.ps1` and related automation write status changes during
maintenance and provisioning runs.

**Mechanism:** `C:\MAST\status\availability.json`

```json
{
  "available": false,
  "reason": "maintenance",
  "since_utc": "2026-05-06T11:00:00Z",
  "expected_return_utc": "2026-05-06T16:00:00Z"
}
```

The MAST scheduler reads this file (via WinRM) before assigning any observation job. A
missing or unreadable file is treated as `available: false` (fail-safe). The file is
written atomically (write to `.tmp`, rename) to avoid partial-read races.

**Lifecycle:**

| Event | `available` | `reason` |
|-------|-------------|----------|
| Maintenance window starts | `false` | `"maintenance"` |
| Provisioning or update running | `false` | `"provisioning"` or `"windows_update"` |
| Reboot in progress | `false` | `"rebooting"` |
| Post-reboot smoke tests pass | `true` | *(field removed)* |
| Smoke tests fail | `false` | `"smoke_failure"` |

**Log events:**

```
[2026-05-06T11:00:00Z] AVAIL_SET  unit=mast01 available=false reason=maintenance
[2026-05-06T11:07:10Z] AVAIL_SET  unit=mast01 available=true  reason=maintenance_complete
[2026-05-06T11:05:00Z] AVAIL_SET  unit=mast01 available=false reason=smoke_failure
```

---

### Observability: Remote one-off scripts (`tools/run-remote-script-winrm.py`) **[DONE]**

Orchestrators invoke ad hoc `.ps1` files on the unit via WinRM HTTP + Basic (chunked
upload). Runs are correlatable with server-side logs and inspectable later.

**On each run the guest sets:**

| Variable | Meaning |
|----------|---------|
| `MAST_RUN_ID` | Correlation id (pass `--run-id` or auto-generated hex). |
| `MAST_REMOTE_INVOKER` | Literal `run-remote-script-winrm.py`. |
| `MAST_REMOTE_SCRIPT_REPO` | Repo-relative script path (forward slashes). |
| `MAST_REMOTE_SCRIPT_PATH` | Full path to the staged temp `.ps1` on the unit. |
| `MAST_REMOTE_LOG_ROOT` | Folder for this tool's transcript + JSON (`C:\MAST\logs\remote-runs`). |

**On-disk artifacts (unit):**

| Path pattern | Content |
|--------------|---------|
| `<SystemDrive>\MAST\logs\remote-runs\remote-<ComputerName>-<run_id>.log` | `Start-Transcript` capture (unless `--no-remote-transcript`). |
| `<SystemDrive>\MAST\logs\remote-runs\remote-<ComputerName>-<run_id>.json` | Machine-readable summary (`kind: mast_remote_run`, exit_code, duration_ms, transcript path, optional error). |

**Stdout markers:** lines beginning with `##MAST##` are emitted at `remote_run_start`,
`remote_run_end`, and on PowerShell `catch` (`remote_error`). The Python driver mirrors
every `##MAST##` line to **stderr** on the orchestrator with a `[guest]` prefix.

**Orchestrator artifact:** optional `--write-local-meta PATH` writes a small JSON record
on the machine running Python (host, run_id, status_code, duration) for CI or auditing.

**Startup wait:** loops until TCP 5985 is open and WinRM accepts Basic auth (defaults:
`--wait-winrm-seconds 900`, `--wait-winrm-poll-seconds 5`). Use `--wait-winrm-seconds 0`
for fail-fast when the unit is already up.

**Convention for custom scripts:** emit `Write-Host "##MAST## kind=phase phase=<name> ..."`
lines for long phases. Prefer reading `$env:MAST_RUN_ID` when appending logs.

**Caveat:** if a child script calls `exit` in the same WinRM runspace, the wrapper's
`finally` may not run; prefer `throw` or non-terminating flow for clean summaries.

**Hang after remote script "Done":** `Enable-PSRemoting` / rebuilding the HTTPS listener
can recycle the WinRM service and drop the same WinRM session the orchestrator is using.
`prepare-mast-client.ps1` avoids calling `Enable-PSRemoting` mid-session when
`MAST_RUN_ID` is set and listeners already exist, and defers HTTPS listener creation to
the last step. Immediately before that step it prints `##MAST## kind=prepare_safe_complete`
as a clear boundary.

**Hang with guest transcript complete but no `remote_run_end`:** `run-remote-script-winrm.py`
no longer calls `Stop-Transcript` in `finally`; `Start-Transcript` output is finalized
when the remote PowerShell process exits right after `##MAST## kind=remote_run_end` and
the JSON summary are written.

**TODO -- robust remote handshake (orchestrator):** Teach `run-remote-script-winrm.py` to
treat `prepare_safe_complete` as a completion milestone: stream stdout during the long WinRM
invoke, exit 0 (or open a fresh WinRM call only for the HTTPS step) once that marker is
seen, instead of blocking until the single SOAP response finishes.

---

### XILab / Standa driver provisioning **[DONE]**

The `stage` provider module (`server/providers/stage/`) installs XILab (the Standa
8SMC4-USB motor controller software) and stages the Standa kernel driver. The installer
runs silently (`/S /NCRC`); the driver is staged unattended via `pnputil /add-driver`.

**What was shipped:**
- `provide-stage.ps1`: pre-trusts the Standa publisher cert, runs the NSIS installer,
  monitors for blocking child processes (e.g. `InfDefaultInstall.exe`) and terminates them
  once files are deployed so the installer exits cleanly, then stages the driver via PnPUtil.
- `verify-stage.ps1`: confirms `XILab.exe` is present at the expected path and writes a
  smoke file.
- Assets: `xilab-1.20.19-win32_win64.exe`, `standa-driver-publisher.cer`.
- `stage` added to all entries in `unit-registry.json` and restored to the default module
  list in `build-mast.ps1` (was disabled 2026-05-14 to 2026-05-15 while the installer hang
  was diagnosed; see DECISIONS.md).

**Exit criteria met:** stage-smoke.txt and stage-verify-smoke.txt written on a clean
VM snapshot in the test cycle; installer exits with code 0 in ~30-50 s.

---

## Phase 1 - Core Correctness

*Goal: eliminate blockers that could cause silent failure or require elevated privileges in
unattended production operation.*

---

### Provisioning server privilege model (non-elevated operation)

The autonomous loop on the **final provisioning machine** should run under a **normal
service account** that is **not** a member of the local Administrators group. That matches
least-privilege deployment and avoids requiring interactive elevation on the server.

**Implication:** patterns that depend on **elevating the provisioning server** must not be
required for core operation.

1. **PowerShell remoting client (`New-PSSession`, `Invoke-Command`, `Copy-Item -ToSession`)**
   often assumes the WinRM **client** on the server machine is configured (for example
   **TrustedHosts** for workgroup targets). Updating machine-wide WinRM client settings
   typically requires **administrator** rights on the **provisioning server**.

2. **Remote execution without elevating the prov server:** `check-and-provision.ps1` uses
   **WinRM over HTTP (5985) with Basic authentication** -- the same surface enabled by
   `client/bootstrap-winrm.ps1` on the unit. This does **not** depend on local
   `TrustedHosts` or `Enable-PSRemoting` on the orchestrator machine. **[DONE]**

3. **Large payload delivery (`staging/` artifacts)** uses **SMB pull**: the unit connects
   to `\\<prov-server>\mast-staging` and copies its payload using `net use` + `robocopy`.
   The orchestrator sends only a short WinRM command to trigger the pull; no credential
   forwarding or CredSSP is required on the provisioning server side. See **Transfer:
   Prov Server -> Unit** for share setup and credential handling. **[DONE]**

4. **`check-and-provision.ps1`** no longer uses `New-PSSession` with `TrustedHosts` or
   `Copy-Item -ToSession`. The current implementation achieves the target end state of
   **non-elevated service + WinRM Basic HTTP + SMB pull transfer**. **[DONE]**

---

### Unit-side provisioning execution control (replace lock-file liability)

`client/execute-mast-provisioning.ps1` uses a simple **lock file**
(`C:\MAST\execute.lock`) to prevent overlapping provisioning runs on the same unit.
That pattern is a **liability** for steady-state operations:

- A crashed guest process, dropped WinRM session, or forced reboot can leave the lock
  file in place and **block all future provisioning** until someone deletes it manually.
- It does not record **lease expiry**, **correlation IDs**, or **which orchestrator run**
  owns the critical section.
- It does not compose cleanly with maintenance windows, intentional operator takeover, or
  fleet-wide status surfaces.

**Requirement:** Replace the sticky lock file with a **more robust** mechanism that still
guarantees **at most one** provisioning execution mutating the machine at a time.

Acceptable directions (pick one coherent approach):

- A **Windows scheduled task** or small **Windows service** that **owns** the provisioning
  execution slot (queue depth 1, explicit states, timeouts, structured logs).
- A **kernel-backed mutex or named semaphore** with **timeouts** and stale-holder
  detection (tied to PID + heartbeat file updated by the owning process).
- A **lease record** under `C:\MAST\status\` written **atomically** (temp file
  then rename), carrying **TTL**, **run_id**, **started_utc**, and optional **held_by**
  identity so the sole provisioning server can **poll**, **expire stale leases**, or follow
  a break-glass procedure without guessing.

Whatever replaces the lock must: **prevent overlapping installs**; **recover without manual
SSH or RDP** after typical failure modes; remain correct when **only one** provisioning
machine drives automation; and expose enough state for **logs and metrics**.

**Concrete design for the lease record** (the recommended direction):

- Path: `C:\MAST\status\execute-lease.json`.
- Fields: `run_id` (string, set from `MAST_RUN_ID`), `started_utc`, `expires_utc`
  (started_utc + TTL), `pid` (owning PowerShell process), `held_by` (hostname of the
  orchestrator that requested the run).
- Acquisition: atomic create-or-replace via `.tmp` + `Move-Item -Force`. Before writing,
  read any existing lease: if `now < expires_utc` **and** `pid` is alive, refuse with a
  structured error (`LEASE_HELD`). Otherwise overwrite (logging `LEASE_STALE_TAKEOVER`
  with the prior `run_id`).
- Renewal: the owning script touches `expires_utc` every 60 s while running (cheap atomic
  rewrite). A consumer can therefore distinguish "actively running" from "abandoned".
- Release: deleted in `finally`. If the script dies, expiry handles recovery.
- TTL: default 2 h, overridable per call via `-LeaseTtlSeconds`. Long enough that a slow
  install does not get preempted, short enough that an abandoned lease clears before the
  next maintenance window.

**Replaces:** `client/execute-mast-provisioning.ps1` lines 39-58 (legacy ProgramData
cleanup + new `C:\MAST\execute.lock` create/throw) and line 252 (`finally` delete).

---

### Availability state recovery (stuck-on-provisioning guard)

The lock-file liability has a **mirror image** in `availability.json`: if
`check-and-provision.ps1` writes `available: false, reason: provisioning` and then
crashes (process kill, prov-server reboot, WinRM blip mid-cycle) before its post-run
`available: true` write, the unit stays excluded from MAST scheduling until someone
notices and rewrites the file by hand. This silently removes a unit from the fleet --
exactly the failure mode autonomous operation must avoid.

**Requirement:** every writer of `availability.json` with `available: false` must include
a bounded `expected_return_utc` and a `lease_owner` (run_id), and every reader (both
`check-and-provision.ps1` on its next cycle and the MAST scheduler) must treat the file
as **stale** once `now > expected_return_utc + grace`.

**Behavior on the next driver cycle:**

1. Read `availability.json`. If `available: false` and `lease_owner` matches a **prior**
   run_id (not the current one) **and** `now > expected_return_utc`, log
   `AVAIL_STALE_RECOVER unit=<name> prior_run=<id> reason=<old reason>` and proceed as
   though the unit were available (the cycle will write a fresh lease for its own run).
2. If `available: false` and the lease is still live, log `AVAIL_LEASE_LIVE` and skip
   the unit -- another in-flight run owns it.
3. On any successful exit path, the cycle writes `available: true` (clearing the lease)
   exactly as today.

**Schema addition to `availability.json`:**

```json
{
  "available": false,
  "reason": "provisioning",
  "since_utc": "2026-05-16T11:00:00Z",
  "expected_return_utc": "2026-05-16T13:00:00Z",
  "lease_owner": "run-20260516-110000"
}
```

`expected_return_utc` is **mandatory** for any `available: false` write. Default TTL:
2 h for `reason=provisioning`, full window for `reason=maintenance`. The MAST scheduler
ignores the file when `now > expected_return_utc + 5 min` and treats the unit as
available.

---

### Driver self-monitoring (heartbeat)

A crashed driver is loud (the scheduled task surfaces a non-zero exit). A **hung**
driver is silent -- the scheduled task is still "running", no `RUN_END` is logged, no
units are touched, and nothing notices until an operator pulls up `activity.csv`.

**Requirement:** the autonomous loop emits a heartbeat that downstream alerting can
watch.

- Each `check-and-provision.ps1` cycle writes `RUN_START` at entry and `RUN_END` at exit
  (already done). Add a **mid-cycle progress** line every 60 s during the long-running
  per-unit steps so a stuck cycle is distinguishable from a cycle that legitimately
  takes 30 min to provision a unit.
- At cycle exit, atomically write
  `C:\MAST\status\last-run.json` containing:
  `run_id`, `started_utc`, `ended_utc`, `units_checked`, `units_updated`, `units_failed`,
  `duration_s`, and the per-unit outcome map. This file is the **single source of truth**
  for "when did the driver last complete a cycle". Phase 3 alerting reads it (or the
  Prometheus metric derived from it) and fires when `now - ended_utc > 2 * scheduled_interval`.
- The scheduled task wrapper logs a Windows Event Log entry on every fire (separate from
  Phase 3's `RUN_END` event) so that "scheduled task fired but driver never wrote
  last-run.json" is detectable.

This is the **prov-server-side** mirror of `availability.json` on the unit: a bounded,
freshness-checkable status file that distinguishes "working" from "abandoned".

---

### Unit provisioning manifest (source of truth)

Each **unit machine** owns and manages its own provisioning state. The provisioning server
must **not** cache or persist per-unit manifest contents on the host. The registry on the
prov server should hold only **discovery and scheduling metadata** -- hostnames, maintenance
windows, module lists used to **build** payloads -- not a mirrored copy of each unit's
installed state.

**Derived state, not a parallel ledger:** it is preferable that the unit **not** treat a
static on-disk manifest file (for example `installed-manifest.json`) as the sole source
of truth. Instead, when probed, the unit should **compute** a manifest from the actual
contents of the machine: installed paths, file hashes or versions where applicable, service
state, and other checksums that reflect what is really present.

**Why:** keeping manifest text on the host, or a manifest file on the unit that is updated
on a different timeline than the filesystem, creates **sync drift**. Inspection-based
manifests avoid contradicting the live system.

The current `installed-manifest.json` written by `execute-mast-provisioning.ps1` is
acceptable as an **optimization or audit artifact**, but the comparison logic should
ultimately align with what a fresh inspection of the unit would produce.

---

### Maintenance window enforcement in `check-and-provision.ps1` **[DONE]**

`unit-registry.json` carries `maintenance_window: { start_hour, end_hour }` and
`timezone` per unit. The driver enforces these windows: disruptive steps (SMB pull,
execute, reboot) are skipped outside the window. Non-disruptive steps (hash check,
skip-if-current) run at any time -- the gate is placed **after** the hash check, so
"already current" outcomes are still logged when outside the window.

**Implementation:** helper `Test-InMaintenanceWindow` in
`server/check-and-provision.ps1` resolves the unit's `timezone` via
`[System.TimeZoneInfo]::FindSystemTimeZoneById`, converts `UtcNow` to that zone, and
returns allowed/current/window/tz. The wrap case (`end_hour < start_hour`, e.g. 22-06)
is handled. A unit with **no** `maintenance_window` field is allowed at any time
(preserves prior behavior for partially configured registries); an invalid timezone
falls back to server local time with a `MAINT_TZ_WARN` log so a typo never blocks the
loop.

**Script parameters:** `-MaintenanceWindowStart` and `-MaintenanceWindowEnd` (24-hour
local, default `-1` = unset). When both are supplied, they override the per-unit
registry values for an ad-hoc fleet-wide push.

**Log line:**

```
[2026-05-16T22:30:00Z] MAINT_SKIP  unit=mast02  reason=outside_window  current=22:30  window=10:00-16:00  tz=America/Los_Angeles
```

Skipped units also get an activity-CSV row with `outcome=SKIP_MAINTENANCE`, distinct
from `SKIP` (already-current / dry-run).

---

### Test-mode exceptions (blockers before production)

While stabilizing the end-to-end flow against a disposable VirtualBox VM, the repo relies
on several **test-mode exceptions**. These must be eliminated before the autonomous
provisioning system is declared production-ready for physical units.

#### 1. SMB share / transfer mechanism **[DONE]**

`check-and-provision.ps1` uses SMB pull exclusively; `Copy-Item -ToSession` is no longer
present. `build-mast.ps1` does not have a `-SkipSmbShare` parameter. Share account
credentials must still be provisioned and stored securely on the unit for production use,
but the code path is correct. This exception is resolved.

#### 2. Paid / sensitive artifacts skipped (licenses)

- **Current exception:** allow missing NoMachine license files during VM testing
  (`-AllowMissingNoMachineLicense`) so paid licenses are not consumed on throwaway VMs.
- **Why it's a blocker:** physical units require correct licensing and must fail loudly if
  licensing inputs are missing.
- **Exit criteria:** add an explicit license allocation policy for real units and require
  the license material for production runs (no "silent skip" outside test mode).

#### 3. Optional GitHub token (mast module)

- **Current exception:** allow missing `vault/tokens/mast_github.txt` during test runs
  (`-AllowMissingGithubToken`) when the `mast` module is not being exercised.
- **Why it's a blocker:** autonomous runs on a real provisioning server must have a clear,
  secure story for repo/LFS credentials (Credential Manager, deploy key, etc.).
- **Exit criteria:** decide how the provisioning server authenticates to Git/LFS and make
  that mandatory for production.

#### 4. Large optional payloads (Astrometry)

- **Current exception:** `server/providers/cygwin/assets/astrometry.tgz` is treated as
  optional in dev/test runs; `provide-cygwin.ps1` skips astrometry expansion if the
  archive is missing.
- **Why it's a blocker:** physical units that rely on astrometry must have the payload
  present and verified (hash, size, version).
- **Exit criteria:** deliver the astrometry payload via an approved channel (Git LFS,
  local artifact cache, offline media), and make it required when the unit's module set
  includes it.

#### 5. Bootstrap security posture (HTTP + Basic)

- **Current exception:** early bootstrap uses WinRM over HTTP (5985) with `Basic` and
  `AllowUnencrypted=true` to simplify first-contact setup.
- **Why it's a blocker:** production should converge to WinRM HTTPS (5986) with
  `AllowUnencrypted=false`, and a defined certificate/validation approach.
- **Exit criteria:** formalize the bootstrap -> steady-state transition and ensure that
  the autonomous loop uses HTTPS by default, with HTTP allowed only for first-boot
  onboarding.

#### 6. Proxy-mode `weizmann` end-to-end coverage

- **Current exception:** the dev VirtualBox VM lives on the host's NAT-ed home network and
  cannot reach `bcproxy.weizmann.ac.il:8080`, so the only proxy mode regularly exercised by
  `vm/run-prov-test.py` is `--proxy-mode direct`. The `weizmann` code paths
  (`provide-proxy.ps1 -ForceMode use`, `provide-astrometry-dependencies.ps1 -ProxyMode use`
  pre-writing `setup.rc` with `net-method=Proxy`, `netsh winhttp set proxy bcproxy:8080`,
  WinINet `ProxyEnable=1`) are unit-test-grade -- they run on every build through the
  argument-plumbing path but their actual network effect against a live proxy is unverified.
- **Why it's a blocker:** production units inside the campus are 100% reliant on the
  `weizmann` path. A regression there would not surface in `direct`-mode dev runs and
  could ship undetected. The risk is concrete: this exact scenario (env vars cleared but
  setup.exe still picking a proxy via IE5/WPAD) was the bug that triggered the
  2026-05-26 redesign; the inverse (env vars set, but setup.exe ignoring them or hitting
  bcproxy at the wrong port) is just as plausible.
- **Exit criteria:** a documented test scenario, runnable on demand against a unit with
  campus-network reachability, that:
  1. Provisions with `--proxy-mode weizmann`.
  2. Asserts `verify-proxy.ps1` exits 0 with smoke body `mode=use ie_enable=1
     ie_server='bcproxy.weizmann.ac.il:8080'`.
  3. Asserts `astrometry-dependencies` succeeds (real download through bcproxy completes).
  4. Asserts a fresh `setup-x86_64.exe` log line says `net: Proxy` and the package fetch
     URLs resolve through the proxy (no 12007s).
  5. Asserts `netsh winhttp show proxy` reports `Proxy Server(s) :
     bcproxy.weizmann.ac.il:8080`.
  6. Asserts HKCU `Internet Settings\ProxyEnable=1`, `ProxyServer=bcproxy.weizmann.ac.il:8080`.

  Tracked as STUB scenario `proxy-weizmann-on-campus` in `vm/test-suite.py`; promote to
  ACTIVE once it has been run successfully against a Weizmann-reachable unit at least once
  and the assertion code is in the harness.

---

### Autonomous recovery from common failure modes

The loop runs unattended on a fixed cadence. Each failure mode below must either
**self-heal on the next cycle** or **expose enough state for a Phase 3 alert** so an
operator can intervene before the unit goes silently offline. None should require a
human to log into a unit to "clean up" before the next cycle can succeed.

| Failure mode | Current behavior | Required behavior |
|--------------|------------------|-------------------|
| `check-and-provision.ps1` crashes between `availability=false` write and post-run `availability=true` write | `availability.json` stays `false` with `reason=provisioning` until next successful run completes the cycle (which may never happen if the same crash recurs). Unit is excluded from scheduling indefinitely. | Availability writer must include a **TTL or `expected_return_utc`** that downstream consumers honor as a stale-after timestamp; the next driver run must detect stale `provisioning`/`maintenance` state and either resume or reset it. |
| Unit-side `execute-mast-provisioning.ps1` killed mid-run (process kill, reboot, power loss) | `C:\MAST\execute.lock` left in place; all subsequent runs throw immediately on the lock check and require **manual deletion** to recover. | See **Unit-side provisioning execution control** above -- lease/TTL with stale-holder recovery. |
| `installed-manifest.json` partially written or corrupt | Hash compare reads garbage; behavior depends on Read-Manifest error handling. | Atomic write (already done via tmp+rename); reader must treat parse failure as "unknown installed state" and reprovision rather than skip. |
| WinRM session drops mid-execute (network blip, listener restart) | Orchestrator gets a SOAP error; activity row written as `EXECUTE_FAIL`; next cycle reprovisions. **OK** but the unit-side run may continue after the orchestrator gives up, racing with the next cycle. | Unit-side execution must be **idempotent across orchestrator retries** -- the lease/TTL replacement is what guarantees this. |
| Provisioning server reboots mid-cycle | No persistent run state; next scheduled fire starts a fresh cycle. **OK.** | Acceptable; keep cycles short enough that "lose the in-flight unit and retry next cycle" is cheap. |
| Disk full on prov server (staging) or unit (downloaded payload) | `build-mast.ps1` or `robocopy` fails with non-zero exit; cycle logs `BUILD_FAIL` / `TRANSFER_FAIL`; next cycle retries forever. | Acceptable for self-healing, **but** Phase 3 must alert on N consecutive `BUILD_FAIL` / `TRANSFER_FAIL` rows in `activity.csv` so the operator notices before the fleet drifts. |
| Git LFS quota exhausted on prov server | `build-mast.ps1` fails to fetch LFS objects; every cycle re-fails with the same error until quota resets. | Acceptable behavior, **but** the failure mode must surface distinctly in logs (recognizable `lfs_quota` reason) so alerts can route differently than a transient build break. Combined with the **Open Questions** entry on LFS credential storage. |
| Stale availability lease | (see row 1) | Pair with `since_utc` + `expected_return_utc`; consumers (MAST scheduler) ignore the file if `now > expected_return_utc + grace`. |
| Reboot loop after Windows Update install | Not yet possible (Phase 2 work). | Once Windows Update orchestration lands, cap consecutive reboots per maintenance window and emit `REBOOT_LOOP_GUARD` rather than continuing to drive reboots. |

**Required additions to `availability.json`** (extends the schema in **Unit Availability
During Maintenance**):

- `expected_return_utc` is **mandatory** for any `available: false` write (already in the
  documented schema -- writers must populate it consistently, not leave it null).
- A separate `lease_owner` field naming the **run_id** that set the state, so a later
  driver run can recognize and supersede its own abandoned writes.

---

## Phase 2 - Operations Resilience

*Goal: make the fleet safe to run unsupervised for weeks; support clean upgrades, planned
reboots, and operator access.*

---

### Long-lived hosts and no resource leaks

**Requirement:** The **provisioning server** and every **unit machine** are expected to
stay up for long stretches (weeks to years). Provisioning automation, modules, helpers,
and observability plumbing must be written so these hosts **do not leak resources** over
time.

Non-exhaustive expectations:

- **Provisioning server:** Close or dispose **WinRM / PowerShell sessions** reliably;
  avoid unbounded growth of **staging directories**, **temp folders**, **log files**, and
  **CSV/history** artifacts (explicit retention, rotation, or cleanup policies where
  writes recur each cycle).
- **Units:** Same discipline for **remote-run transcripts**, **staging paths**, **partial
  download debris**, and **child processes** launched during provisioning (installers must
  finish or be bounded; no accumulating orphan tasks).
- **Design reviews:** Treat monotonic growth (handles, threads, disk, registry clutter
  from duplicate firewall rules, etc.) as **bugs**, not operational trivia.

Dev-only shortcuts (for example short-lived HTTP servers on a workstation) must **not**
become silent production defaults unless they include explicit **lifecycle** (startup,
shutdown, port reuse) and **cleanup** semantics compatible with an always-on host.

---

### Staging area lifecycle and shared-payload deduplication

**Current state:** `build-mast.ps1` writes to `staging\<hostname>\01-provisioning\` per
unit. Today every unit gets the **same** module set (see **Unit profiles**), so the
build is copying the same multi-GB asset tree once per unit -- identical bytes,
identical hashes, N copies on disk on the prov server. After unit profiles land,
two units sharing a profile will still produce byte-identical payloads, so the
duplication problem grows with fleet size rather than going away.

**Requirement:** the build pipeline must **stage shared content once** and reuse it
across units that resolve to the same effective module set.

Acceptable directions (pick one coherent approach):

- **Profile-keyed staging:** stage to `staging\by-profile\<profile_hash>\` where
  `profile_hash` is a hash of the resolved module list plus their pinned versions.
  Each unit gets a tiny per-host directory (`staging\<hostname>\`) that contains only
  unit-specific files (per-host config, smoke expectations) and a pointer or
  hardlink/junction tree into the shared profile payload. SMB share exposes
  `by-profile\<hash>\`; the WinRM trigger tells the unit which profile hash to pull.
- **Content-addressed object store:** every staged file is written once under
  `staging\objects\<sha256>` and per-unit trees are reconstructed as a manifest of
  hashes. The unit's pull resolves the manifest against the object store. More work
  to build, but each new module version only adds the new bytes.
- **NTFS hardlinks across per-host directories:** keep `staging\<hostname>\` as
  today, but in `build-mast.ps1` detect when a file's content matches an existing
  staged file and use `New-Item -ItemType HardLink` instead of copying. Cheap to
  retrofit; preserves the existing on-disk layout; storage cost drops to one copy
  per unique file.

Whatever the mechanism, the **payload_hash** contract is unchanged: two units that
resolve to the same effective profile must produce the same `payload_hash`, and the
drift-detection comparison on the unit side remains identical to today.

**Staging retention and cleanup:** monotonic growth of `staging\` is a bug (see the
parent section on resource leaks). The build must own its lifecycle:

- After a successful build, **prune** profile/object-store entries whose hash is no
  longer referenced by any unit in `unit-registry.json` and whose age exceeds a
  rollback grace window (proposed: 7 days, configurable).
- Per-host directories are torn down and rebuilt each cycle; no stale per-host files
  may survive from a prior build (today's `staging\<hostname>\` is implicitly
  overwritten, but the contract should be explicit and tested).
- Log `STAGING_PRUNE removed=<N> bytes_reclaimed=<M>` at the end of each build so
  growth or lack of pruning is visible in `activity.csv`.

**Do not edit `staging/`** still applies (see `CLAUDE.md`): the directory is
generated. The change here is to **how** it is generated, not to operator workflow.

---

### Package lifecycle, MAST version pinning, rollback, and observability

#### Dropping in a newer package version

Upgrading a package must require **no code changes** -- only replacing the installer asset
and bumping the version reference:

1. Drop the new installer (EXE, MSI, ZIP, TGZ, etc.) into the provider's `assets/`
   directory, replacing or alongside the old file.
2. Update the version reference in `module.json` (or a dedicated version field) to point
   at the new asset.
3. Run `build-mast.ps1` -- the new asset is staged, the `payload_hash` changes, and on
   the next provisioning cycle every unit that does not yet have the new hash will be
   updated automatically.

No other script changes should be necessary for a routine version bump. A provider's
`provide-<name>.ps1` must therefore **not** hard-code installer filenames or version
strings; it must read them from `module.json` or derive them from the asset present in
`AssetsRoot` (e.g. by glob pattern). This also means adding a brand-new package to the
fleet is the same operation: add a provider directory with `module.json` and
`provide-<name>.ps1`, drop in the asset, add the module name to the relevant entries in
`unit-registry.json`, and the next build+provision cycle picks it up.

#### Per-package uninstall and reinstall

Upgrades must be **clean**: for each provisioned **package/module**, automation needs
**full control** to **uninstall** and **reinstall** that module alone (or run an
equivalent **repair** that resets the same surface area). Layering new files on top of a
broken, partial, or manually altered install is not acceptable as the only strategy.
Module boundaries should expose **paired** operations -- install, uninstall/teardown, then
install again -- so the fleet can recover from corruption and so major version jumps do
not inherit stale registry keys, services, or paths.

#### Pinning and rolling MAST services by git tag or commit

**Operational contract:**

- `build-mast.ps1` (and any prerequisite git checkout / fetch step on the prov server)
  must support targeting a **pinned ref** so staged artifacts correspond to a **known**
  revision.
- **Rollback** is **deploying a prior ref** through the same pipeline (build -> transfer
  -> execute), subject to schema/data compatibility and operator policy -- not ad hoc file
  swaps on the unit.
- Drift detection compares **effective** identity on the machine (from inspection) to the
  **intended** ref for that rollout.

Pinning parameters may surface as flags, config on the prov server, or optional fields in
discovery metadata (for example per-unit or fleet-wide **target ref**), but the prov
server still does **not** store a cached copy of what is installed -- only what **should**
be built for the next action.

#### Full observability without caching machine state on the prov server

- **Truth for control plane decisions** comes from **fresh** probes each cycle (and/or
  scrape targets that read live state on the unit), compared to the **build** produced for
  that run.
- **Monitoring systems** (Prometheus time series, log aggregation) store **history for
  humans and alerts**; that is **telemetry**, not the authoritative "installed state"
  database for `check-and-provision`. Avoid duplicating "current manifest" rows on the
  prov server **for automation** -- use live inspection or metrics emitted **from** the
  unit.

---

### Windows Updates and Scheduled Reboots

The flow below is the **intended** maintenance-window behavior once `check-and-provision.ps1`
implements scheduling integration and update orchestration.

#### Principle: daylight hours only

MAST units are observatory machines. Sky observations run at night. All disruptive
maintenance -- Windows Updates, reboots, and any sysadmin tasks that take the unit offline
-- should be confined to **daylight hours** (nominally 10:00-16:00 local site time), when
no science data can be collected regardless.

#### Disable automatic updates during initial provisioning **[DONE]**

Before running `execute-mast-provisioning.ps1`, Windows Update is prevented from
installing updates and rebooting mid-run. This is implemented in `prepare-mast-client.ps1`:

```powershell
# Disable automatic update installation during provisioning.
$auPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $auPath -Force | Out-Null
Set-ItemProperty -Path $auPath -Name NoAutoUpdate   -Value 1 -Type DWord
Set-ItemProperty -Path $auPath -Name AUOptions      -Value 1 -Type DWord
Set-ItemProperty -Path $auPath -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord
Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Set-Service  wuauserv -StartupType Disabled
```

After provisioning completes, `execute-mast-provisioning.ps1` restores the unit to
managed download-only policy:

```powershell
Set-ItemProperty -Path $auPath -Name AUOptions -Value 3 -Type DWord
Remove-ItemProperty -Path $auPath -Name NoAutoUpdate -ErrorAction SilentlyContinue
Set-Service  wuauserv -StartupType Automatic
Start-Service wuauserv
```

#### Windows Update policy (steady-state)

Configure each unit via Group Policy or registry to **download but not install** updates
automatically. Installation is triggered by `check-and-provision.ps1` during the
maintenance window so the provisioning server controls timing.

```powershell
# Disable automatic install; allow download only (AUOptions = 3)
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' `
    -Name AUOptions -Value 3 -Type DWord
```

#### Update + reboot sequence (inside maintenance window only)

**Target:** `check-and-provision.ps1` runs this sequence after all units are provisioned:

```
for each unit in unit-registry.json (inside maintenance window):
  1. Check for pending Windows Updates via PSWindowsUpdate or WUA COM API
     - none pending -> log WUPDATE_SKIP reason=no_pending, skip
  2. Install pending updates via WinRM:
       Invoke-Command -> Install-WindowsUpdate -AcceptAll -AutoReboot:$false
     - Log each KB number installed to activity.csv
  3. Check if reboot is required (PendingReboot registry key)
  4. If reboot required:
     a. Check time: if < 30 min before MaintenanceWindowEnd, defer to next day
     b. Log REBOOT_START unit=<name> reason=windows_update
     c. Invoke-Command -> Restart-Computer -Force
     d. Wait for WinRM to come back (up to 10 min)
     e. Log REBOOT_OK unit=<name> elapsed_s=<n>
  5. Re-run smoke tests post-reboot to confirm unit is healthy
```

#### PSWindowsUpdate module

`check-and-provision.ps1` will depend on the
[PSWindowsUpdate](https://www.powershellgallery.com/packages/PSWindowsUpdate) module on
each unit, installed once during initial provisioning:

```powershell
Install-Module PSWindowsUpdate -Force -Scope AllUsers
```

Add this to `execute-mast-provisioning.ps1` or as a dedicated `windowsupdate` module in
the provisioning pipeline.

#### Log events

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

#### Deferred reboots

If a reboot is pending but there is less than 30 minutes left in the maintenance window,
the reboot is deferred. The unit is marked `REBOOT_DEFERRED` in `activity.csv` and
retried on the next day's maintenance run.

#### Maintenance summary

| Task | Runs when |
|------|-----------|
| MAST provisioning (software install) | Inside maintenance window |
| Windows Update check + install | Inside maintenance window |
| Reboot (if required) | Inside maintenance window, >= 30 min remaining |
| Smoke test re-run post-reboot | Immediately after reboot completes |
| Hash check, skip-if-current | Any time |

---

### Unit profiles (future hardware variation) -- placeholder

**Current state:** All fleet units are identical hardware running the same module set.
Every entry in `unit-registry.json` receives the same `modules` list and no
hardware-specific configuration exists. **This is duplication** -- the same module
array is copy-pasted into every unit row, and adding a module today means editing
every entry. The registry is the source of truth for "which modules each unit gets"
**and** it is the only place this drift can be introduced silently.

**Future requirement:** As the fleet grows, hardware may diverge -- different camera
models, mount types, focusers, or other attached instruments. When that happens, a single
flat module list per unit will not be sufficient; the provisioning system must be able to
assign a **profile** to each unit that determines which packages are installed, which
configuration values are applied, and which smoke checks are expected.

**DRY requirement for `unit-registry.json`:** this feature is also the mechanism that
**eliminates the current duplication**. A unit entry should reference a named profile
(e.g. `"profile": "standard-scope"`) and the profile definition -- including its
`modules` list -- lives **once**, in a separate file (proposed: `unit-profiles.json`
alongside `unit-registry.json`, or a `profiles/` subdirectory). After the feature
lands:

- Every entry in `unit-registry.json` carries only **unit-specific** fields: hostname,
  `maintenance_window`, `timezone`, `profile`, and any per-unit overrides
  (hardware serials, COM ports). No `modules` array per unit by default.
- The profile file defines the canonical module list for each profile name. Adding a
  module to the fleet is **one edit** in the profile file, not N edits across the
  registry.
- Per-unit overrides remain possible (e.g. `"modules_add": ["zwo-asi294"]`,
  `"modules_remove": ["phd2"]`) so a single divergent unit does not force a new
  profile, but the **default** is "inherit from profile".
- `build-mast.ps1` and `check-and-provision.ps1` resolve the effective module list
  per unit by merging `profile.modules` with `modules_add`/`modules_remove` at build
  time. Drift detection continues to operate on the resolved list, so two units on
  the same profile share a `payload_hash` when their override sets are equal.

This makes "what modules go where" auditable from a single small file, removes the
copy-paste hazard that already exists today, and lays the groundwork for hardware
variation without a second migration later.

**Design constraints to keep in mind now** (no implementation required today):

- A `profile` field (e.g. `"profile": "standard-scope"`) maps to a named module set
  and configuration block defined elsewhere, so `unit-registry.json` stays concise
  while the profile definition lives in a separate file. See the **DRY requirement**
  above -- the profile file is the source of truth for "what does a standard unit
  get", not a per-unit duplicated `modules` array.
- Per-unit overrides (`modules_add`, `modules_remove`, hardware-specific config blocks)
  remain first-class so a single divergent unit does not require minting a new
  profile. The default is "inherit from profile"; overrides are the exception.
- Provider scripts (`provide-<name>.ps1`) must not hard-code assumptions that all units
  share the same hardware. Any hardware-specific configuration (driver paths, COM port
  assignments, camera serial numbers) should be injectable via parameters or a per-unit
  config block, not baked into the script.
- Build and drift-detection logic must remain correct when two units have different module
  sets: the `payload_hash` for `mast01` and `mast02` may legitimately differ if they
  carry different profiles, and the provisioning server must not treat that as an error.
- Smoke checks are profile-specific: a unit without a ZWO camera should not be expected
  to pass a ZWO smoke check. The smoke check set must be derived from the unit's actual
  module list, not a global list.

**When this becomes active work:** when the first unit is onboarded with a hardware
configuration that differs from the standard setup. At that point, promote this
placeholder into a concrete implementation plan, add a `profile` schema to
`unit-registry.json`, and audit all provider scripts for hard-coded hardware assumptions.

---

### Fleet SSH server (operator remote access)

**Requirement:** Every MAST unit in the fleet must ship with an **SSH server** enabled for
steady-state operation: installed, configured for site policy (listen address, port, allowed
users or groups), set to **start automatically** with the OS, and **running** so operators
can `ssh` to `mastNN` by hostname. Provisioning automation remains on **WinRM**; SSH is
for **human-driven** remote shells and tooling.

**Windows:** Use the platform **OpenSSH Server** optional capability (or equivalent
supported distribution), harden host keys and `sshd_config`, and restrict access with
**firewall rules** (for example allow TCP 22 only from management subnets or jump hosts).
Document the **expected smoke check** (for example: service `sshd` Running, port reachable
from a defined bastion) so **Observability** can treat SSH availability like other fleet
services.

**Security:** Key-based auth, deny-password where policy allows, patch cadence aligned with
Windows Update, and no overlap with insecure bootstrap shortcuts. SSH must not weaken the
steady-state posture described under **Test-mode exceptions** for WinRM HTTPS.

---

## Phase 3 - Observability

*Goal: make fleet state visible, queryable, and alertable without logging into individual
units.*

---

### Log files on the prov server (`C:\MAST\logs\prov\`) **[PARTIAL]**

Activity CSV and session logs exist. The structured event tokens below (used consistently
in run logs) are the remaining gap.

**Target layout:**

| File | Content | Retention |
|------|---------|-----------|
| `run-<timestamp>.log` | Full per-run detail log (see below) | Keep last 30 runs |
| `activity.csv` | One-line summary per unit per run | Rolling, keep 90 days |
| `package-timings.csv` | One row per package per provisioning run; basis for statistics | Rolling, keep 90 days |
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
[2026-05-05T14:01:30Z] BUILD_OK     unit=mast02 duration_s=45 payload_hash=b7e2...
[2026-05-05T14:01:30Z] HASH_CHECK   unit=mast02 installed=<none> built=b7e2... result=NEEDS_UPDATE
[2026-05-05T14:01:31Z] TRANSFER_START  unit=mast02 files=41 bytes=1362534400
[2026-05-05T14:09:15Z] TRANSFER_OK     unit=mast02 duration_s=464
[2026-05-05T14:09:16Z] EXECUTE_START   unit=mast02
[2026-05-05T14:09:17Z] PKG_START       unit=mast02 module=python order=20 version=3.12.0
[2026-05-05T14:11:42Z] PKG_OK          unit=mast02 module=python order=20 version=3.12.0 duration_s=145
[2026-05-05T14:11:42Z] PKG_START       unit=mast02 module=ascom  order=30 version=7.1.0
[2026-05-05T14:55:00Z] PKG_FAIL        unit=mast02 module=ascom  order=30 version=7.1.0 duration_s=2598 exit_code=1
[2026-05-05T14:55:00Z] EXECUTE_FAIL    unit=mast02 duration_s=2744 exit_code=1 failed_module=ascom
[2026-05-05T14:55:01Z] SMOKE_START     unit=mast02
[2026-05-05T14:55:05Z] SMOKE_RESULT    unit=mast02 module=python status=OK
[2026-05-05T14:55:05Z] SMOKE_RESULT    unit=mast02 module=ascom  status=FAIL reason=smoke_file_missing
[2026-05-05T14:55:05Z] UNIT_FAIL       unit=mast02 reason=smoke_failures modules=ascom
[2026-05-05T14:55:05Z] RUN_END  units_checked=2 units_updated=1 units_failed=1 duration_s=2704
```

Key design rules:
- Every event has an ISO 8601 UTC timestamp and a fixed `EVENT_TYPE` token so logs are
  `grep`-able and machine-parseable.
- `EXECUTE_START` / `EXECUTE_OK` / `EXECUTE_FAIL` bracket the long-running provisioning
  step so you can see exactly where time is spent.
- `PKG_START` / `PKG_OK` / `PKG_FAIL` bracket each individual package installation.
  `PKG_FAIL` always names the failing module and its `duration_s` so a stuck or
  slow installer is immediately identifiable without parsing full transcripts.
- `TRANSFER_START` logs the total file count and byte count so stalls are immediately visible.
- Each `SMOKE_RESULT` line names the module and the failure reason.
- `UNIT_SKIP` / `UNIT_FAIL` / `UNIT_OK` give a machine-readable per-unit outcome.
- On unexpected exceptions, an `EXCEPTION` event is written with the full stack trace.

#### `activity.csv` schema **[PARTIAL]**

```
timestamp_utc, run_id, unit, outcome, reason, duration_s, payload_hash, git_sha
2026-05-05T14:55:05Z, run-20260505-140000, mast01, SKIP,    already_current, 1,    a3f9..., abc1234
2026-05-05T14:55:05Z, run-20260505-140000, mast02, FAIL,    smoke:ascom,     2704, b7e2..., abc1234
```

`outcome` is one of: `OK`, `SKIP`, `FAIL`, `UNREACHABLE`, `BUILD_FAIL`, `TRANSFER_FAIL`,
`EXECUTE_FAIL`.

#### `package-timings.csv` schema

One row is written per package per provisioning run by `execute-mast-provisioning.ps1`
on the unit and relayed to the prov server (or written directly if the prov server polls
the unit). This file is the primary source for installation time statistics.

```
timestamp_utc, run_id, unit, module, version, order, outcome, duration_s, exit_code
2026-05-05T14:11:42Z, run-20260505-140000, mast02, python,  3.12.0, 20, OK,   145, 0
2026-05-05T14:55:00Z, run-20260505-140000, mast02, ascom,   7.1.0,  30, FAIL, 2598, 1
```

`outcome` per row is `OK`, `FAIL`, or `TIMEOUT`. `duration_s` is wall-clock seconds from
`PKG_START` to `PKG_OK` / `PKG_FAIL`, including any installer UI wait or subprocess.
`version` is read from `module_versions` in `build-manifest.json` at the time the run
is staged -- it reflects the version that was attempted, even if installation failed.

**Use cases:**
- Identify stuck or unexpectedly slow installers across runs and units by sorting on
  `duration_s` per module.
- Track installation time trends over software version bumps (e.g. python 3.12 -> 3.13
  takes N% longer) by grouping on `version`.
- Correlate failures or timeouts with a specific version: if `ascom 7.1.0` started
  failing across units after a version bump, the version column makes that immediately
  visible without cross-referencing git history.
- Confirm a rollback landed: after rolling back to a prior version, the `version` column
  in subsequent runs should reflect the older version on all units.
- Set per-package timeout thresholds in `module.json`; flag runs where `duration_s`
  exceeds the threshold as `TIMEOUT` even if the installer eventually returned 0.
- Aggregate mean and p95 install time per module and version across the fleet for
  capacity planning and regression detection.

**Per-package timeout:** `module.json` should support an optional `timeout_s` field. If
the package installer has not completed within that threshold, `execute-mast-provisioning.ps1`
terminates the process, logs `PKG_FAIL ... outcome=TIMEOUT`, and fails the run for that
unit. This prevents a single hung installer from blocking the provisioning slot indefinitely.

---

### Progress visibility during long operations

Long-running phases (transfer, execute) write heartbeat lines every 30 seconds:

```
[2026-05-05T14:09:00Z] TRANSFER_PROGRESS  unit=mast02 files_done=28/41 bytes_done=950000000/1362534400
[2026-05-05T14:30:00Z] EXECUTE_PROGRESS   unit=mast02 elapsed_s=1244 last_module=mongodb
```

**Target:** `execute-mast-provisioning.ps1` writes per-module progress to a sidecar file
such as `C:\MAST\logs\prov\execute-progress.txt` on the unit, which the prov server polls
via WinRM during execution and relays into the run log.

---

### Windows Event Log integration

Each `RUN_END` writes a single Windows Event Log entry (source: `MAST-Provisioning`,
Event ID 1000=OK, 1001=partial failure, 1002=run error), so monitoring agents (Zabbix,
Datadog, etc.) can pick up outcomes without parsing log files.

---

### Alerting

`check-and-provision.ps1` should accept an optional `-AlertEmail` parameter. If set, it
sends a plain-text summary via `Send-MailMessage` when any unit ends `FAIL` or
`UNREACHABLE`. Subject line example: `[MAST] Provisioning alert: mast02 FAIL (smoke:ascom)`.
No email on all-OK or all-SKIP runs.

---

### Prometheus scrape targets and central command dashboard

Operators and automation must be able to see **fleet-wide** answers without logging into
each unit: what payload/modules are effective, which MAST services are running, and
whether each layer last reported healthy. That state must be **scraped by Prometheus** (or
a compatible pull-based collector) and rendered on a **central command dashboard**.

#### Principles

1. **Pull model:** Prometheus scrapes **HTTP(S)** endpoints on a documented interval.
   Units and the provisioning server participate as **first-class scrape targets**.
2. **Same truth as provisioning:** Metrics that describe **installed payload hash**,
   **module versions**, and **drift** must align with the **effective** manifest described
   under **Unit provisioning manifest** so the dashboard never contradicts
   `check-and-provision` decisions.
3. **Low-cardinality labels:** Use stable label keys (`hostname`, `site`, `module`,
   `service`, `component`). Avoid unbounded label values (full file paths, raw error
   stacks).
4. **Security:** Scrape paths reachable only from the monitoring segment; prefer TLS and
   auth where site policy requires it.

#### Implementation patterns (non-prescriptive)

Pick one or combine:

- **windows_exporter** plus optional **textfile collector** directory: a scheduled job
  or small agent on each unit **atomically** writes `*.prom` snippets for custom facts
  (payload hash, module versions).
- A **small MAST-specific exporter** (single HTTP server) that gathers the same facts the
  unit probe would use (filesystem, services, optional WMI) and exposes OpenMetrics /
  Prometheus text format on `/metrics`.
- **Pushgateway** only where pull from the unit is impossible (firewall exception);
  default is **direct scrape** of the unit from Prometheus.

#### Installed package / manifest exposure

- **Gauge or info-style metrics:** `mast_payload_hash` as an info metric with labels for
  git SHA and payload hash.
- **Per-module signals:** `mast_module_present{unit, module} == 1` and
  `mast_module_version_info{unit, module, version} == 1`. The `version` label is
  **required** (not optional) -- it is sourced from `module_versions` in
  `installed-manifest.json` so the dashboard always shows what version is actually on
  each unit, not just whether the module is present.
- **Drift vs build:** If the prov server publishes the **current** `build-manifest` hash
  and `module_versions` for that unit's module set, the dashboard can compare
  **effective** vs **desired** version per module in one place -- making it immediately
  visible when a unit is running an old version after a failed or pending upgrade.

Goal: the central dashboard shows a **table or stat panel per unit**: expected vs effective
hash, per-module installed version vs desired version, and age of last successful
alignment.

#### Package installation timing and statistics

`package-timings.csv` (see **Log files** above) is the raw data source. The prov server
or a scrape-time aggregator exposes timing history as Prometheus metrics so the Grafana
dashboard can surface slowness and regressions without log-file parsing.

**Metrics to expose (sourced from `package-timings.csv` on the prov server):**

- `mast_pkg_install_duration_seconds{unit, module, version, outcome}` -- gauge of the
  most recent install duration for each unit+module combination. The `version` label
  makes it possible to compare install time for the same module across versions directly
  in Prometheus without joining against another data source.
- `mast_pkg_install_duration_seconds_hist{module, version}` -- histogram (or summary)
  across all units and recent runs, for p50/p95 per-module per-version fleet-wide install
  time. Helps set realistic timeout thresholds in `module.json` and detect regressions
  introduced by a specific version bump.
- `mast_pkg_timeout_total{unit, module, version}` -- counter incremented each time a
  package install hits its `timeout_s` limit. An increasing counter on a specific
  module+version is an early signal of a broken installer or environment regression
  introduced by that version.
- `mast_pkg_last_outcome{unit, module, version}` -- 1 if the most recent install of that
  module on that unit was `OK`, 0 if `FAIL` or `TIMEOUT`. The `version` label means the
  dashboard can show "mast02 is running ascom 7.0.0 (OK) while the fleet is on 7.1.0
  (FAIL)" without a separate query.

**Alerting rules:**

- Fire when `mast_pkg_install_duration_seconds{module}` for any unit exceeds 2x the
  fleet p95 for that module on the previous N runs (likely hung installer).
- Fire when `mast_pkg_last_outcome == 0` for any module persists across two consecutive
  provisioning cycles (persistent install failure, not a transient glitch).
- Fire when `mast_pkg_timeout_total` increments for any unit+module (any timeout is
  worth an immediate alert).

**Grafana panels:**

- **Package timing heatmap:** rows = modules, columns = recent runs, cell colour = install
  duration, cell label = version. Regressions from a version bump are immediately visible
  as a colour shift on the affected module row, annotated with the version that caused it.
- **Per-unit package status table:** one row per unit, columns per module, cell shows
  installed version and green/red from `mast_pkg_last_outcome`. A unit running a
  different version than the fleet target is highlighted. Replaces manual log inspection
  to confirm a fleet-wide deploy or rollback landed cleanly.
- **Fleet install time trends:** line chart of p50 and p95 install duration per module,
  with version changes marked as annotations. Reference baseline for setting `timeout_s`
  values and spotting install time regressions introduced by specific version bumps.

#### Running MAST services manifest

Enumerate MAST-related Windows services and expose **running / stopped / missing** in a
scrape-friendly form:

- `mast_expected_service{service="..."} == 1` paired with `windows_service_state` from
  windows_exporter, or
- Custom `mast_service_up{service="..."}` (1 when Running and expected, 0 otherwise).

Include **start mode** where useful (Automatic vs Manual) so misconfiguration is visible.

#### MAST application service logs

Each MAST telescope control service writes its stdout and stderr to NSSM-managed log files on
the unit. These files are the primary source of application-level errors and should be shipped
to a central log store (Loki, Elastic, or equivalent) alongside Prometheus metrics.

**Log file locations (per unit):**

| Service | stdout | stderr |
|---------|--------|--------|
| `MAST_unit` | `C:\MAST\logs\mast-unit\stdout.log` | `C:\MAST\logs\mast-unit\stderr.log` |
| `PWI4` | `C:\MAST\logs\pwi4_stdout.log` | `C:\MAST\logs\pwi4_stderr.log` |
| `PWShutter` | `C:\MAST\logs\pwshutter_stdout.log` | `C:\MAST\logs\pwshutter_stderr.log` |

All three services are configured with `AppRotateFiles=1` and `AppRotateBytes=10485760`
(10 MB). A log shipping agent (e.g. Promtail, Fluent Bit, or Elastic Agent) should tail
these files and forward structured entries to the central store.

**What to monitor in MAST_unit logs:**

- Startup sequence: PWI4 connection established, PWShutter found, ps3cli health check result.
- Python exceptions / tracebacks -- any `ERROR` or `Traceback` line from the FastAPI
  service warrants an alert.
- Component state changes logged by the `Activities` bitflag tracker (startup, shutdown,
  operational transitions).
- WS disconnect or reconnect bursts (may indicate network instability on the unit).

**Grafana panels:**

- **Log viewer per unit:** Loki datasource filtered on `{job="mast_unit", hostname="mastNN"}`,
  showing the last N lines of MAST_unit stdout/stderr interleaved.
- **Error rate panel:** count of log lines matching `level=ERROR` or `Traceback` per unit
  per time window; alert when rate exceeds baseline.
- **Service restart counter:** derived from NSSM or Windows Event Log entries for
  `MAST_unit` service state transitions; a climbing restart count indicates a crash loop.

**Retention and cleanup:** the NSSM rotation caps individual files at 10 MB. The log
shipping agent should retain at least 7 days of history in the central store.
Provisioning tooling that resets or rebuilds a unit (`--pull-repos`, `--rebuild-repos`
in `run-prov-test.py`) stops the service and deletes the on-unit log files before
restart so stale entries from a previous code version do not pollute the next session.

---

#### Observability agents -- future provisioning modules

Prometheus scraping, log shipping, and the unit-side status endpoint each require
software that is **not** currently installed by `execute-mast-provisioning.ps1`.
These should land as **new provider modules** under `server/providers/` so they
are built, transferred, executed, smoke-checked, version-pinned, and drift-detected
through the same pipeline as everything else -- not bolted on with an out-of-band
installer. Each gets its own `provide-<name>.ps1`, `verify-<name>.ps1`,
`module.json` with `version` field, and `assets/` directory; each gets added to
the relevant unit profiles (see **Unit profiles** in Phase 2).

| Module | Purpose | Notes |
|--------|---------|-------|
| `windows-exporter-monitoring` | Base Prometheus scrape target for OS-level metrics (CPU, memory, disk, network, services, scheduled tasks). | Install MSI from `assets/`; configure collectors (`cpu`, `cs`, `logical_disk`, `memory`, `net`, `os`, `service`, `system`, `scheduled_task`, `textfile`). Open TCP 9182 to the monitoring subnet only. Enable the `textfile` collector with directory `C:\MAST\status\textfile_inputs\` so other modules can drop `*.prom` snippets. |
| `mast-exporter` | MAST-specific HTTP server exposing `/metrics` (manifest, module versions, service state, lease, availability, drift) and the `/status/*` + `/health` routes defined under **Unit state via HTTP endpoint**. | Small NSSM-managed service. Reads `installed-manifest.json`, `availability.json`, `execute-lease.json`, `last-execute.json`, and (optionally) the live filesystem probe. Bound to the management subnet. Versioned independently of MAST app code so observability does not block app deploys. |
| `mast-textfile-writer` | Scheduled task that atomically writes `mast.prom` into the windows_exporter textfile collector directory. | Alternative or supplement to `mast-exporter` for sites that prefer the textfile-collector pattern. One canonical implementation in `client/mast-write-textfile-metrics.ps1`; the module just installs the scheduled task entry. |
| `log-shipper` | Tail NSSM stdout/stderr logs (`MAST_unit`, `PWI4`, `PWShutter`) and forward to the central log store (Loki / Elastic). | Pick one of Promtail, Fluent Bit, or Elastic Agent at the **fleet** level -- not per-unit. Config is a profile-level template that names the central endpoint and the file list. Service runs under a constrained account with read-only access to the log paths. |
| `pswindowsupdate` | Prerequisite for Phase 2 Windows Update orchestration; also a source of update-related metrics (`pending_update_count`, `last_update_install_utc`). | `Install-Module PSWindowsUpdate -Force -Scope AllUsers`. Module is small but versioning matters -- pin the gallery version in `module.json`. Smoke check verifies `Get-WUList` runs without error. |
| `ntp-sync` | Configure `w32time` against the site NTP server(s) and verify drift is within tolerance. | Resolves the open question on clock skew under **Open Questions**. Smoke check fails if `w32tm /stripchart` reports drift greater than a configurable threshold (default 5 s). Required for maintenance-window correctness and lease TTL semantics. |
| `sshd` (operator SSH) | Already specified under **Fleet SSH server (operator remote access)** in Phase 2; included here because its smoke check (port reachable, service Running) is a first-class observability signal. | Cross-reference, not a duplicate work item. |

**Sequencing:**

1. `windows-exporter-monitoring` lands first -- gives the dashboard immediate signal (CPU,
   disk, services) with no MAST-specific code.
2. `mast-exporter` (or `mast-textfile-writer`) lands second -- exposes manifest,
   lease, and availability so the dashboard can answer "is mast03 in maintenance
   and on the right hash" without WinRM.
3. `log-shipper` lands third -- ships MAST app logs so error rate panels and
   crash-loop detection can be wired up.
4. `pswindowsupdate` and `ntp-sync` are independent of the observability rollout
   but block other Phase 1/2 work (Windows Update orchestration, clock-skew
   correctness); they should not wait for the observability push.

**Module set membership:** these modules are added to the **observability**
profile (or to the default profile, depending on site policy) -- not hardcoded
into every unit's module list. A dev VM running `run-prov-test.py` should be
able to opt out of `log-shipper` and `windows-exporter-monitoring` to keep test cycles fast.

**Drift detection alignment:** each new module participates in `payload_hash`
and `module_versions` like any other. The exporter must read its own version
from `installed-manifest.json` so the dashboard can show "mast05 is running
`mast-exporter 1.4.0` while the fleet target is 1.5.0" -- the observability
plane must not be a blind spot in its own drift detection.

**Prov-server side:** the provisioning server itself needs a parallel set of
agents -- `windows-exporter-monitoring` for OS metrics, plus a `prov-server-exporter` that
reads `last-run.json`, tails `activity.csv` and `package-timings.csv`, and emits
the `mast_prov_*` and `mast_pkg_*` metrics specified under **Package
installation timing and statistics** and **Heartbeats and liveness**. The prov
server is not provisioned by `check-and-provision.ps1` (it would be circular),
so this is a separate installer script under `server/install-observability.ps1`
rather than a provider module. Versioning still tracked through `build-manifest`
so the fleet sees a consistent observability surface.

---

#### Unit state via HTTP endpoint (not just WinRM)

**Current state:** every fact about a unit's provisioning state -- `availability.json`,
`installed-manifest.json`, `execute-lease.json`, `last-run.json` -- is a file on the
unit, readable only by opening a WinRM session and either invoking PowerShell or
mounting an SMB path. The MAST scheduler, dashboards, and external monitors all need
WinRM credentials and a Windows-savvy client to answer "is mast03 available?" or
"what payload hash does mast05 have?". This couples every consumer to the
provisioning credential surface and makes Prometheus scraping awkward (the
windows_exporter / textfile collector pattern in **Implementation patterns** above
helps for metric-shaped data, but does nothing for the JSON status files the
provisioning loop already maintains).

**Requirement:** each unit exposes its provisioning state on an **HTTP endpoint**
that is readable without WinRM. The same MAST-specific exporter described in
**Implementation patterns** is the natural host -- it already runs on each unit and
already serves `/metrics`. Add status routes alongside it:

| Route | Returns | Source |
|-------|---------|--------|
| `/health` | Liveness probe: 200 if the unit's MAST services are up and the provisioning subsystem is not in a failed state; 503 otherwise. Compact JSON body with `status`, `available`, `provisioning_state`, `last_run_age_s`. | Aggregates the files below. |
| `/status/availability` | Current `availability.json` verbatim (with `expected_return_utc` honored for staleness). | `C:\MAST\status\availability.json` |
| `/status/manifest` | Effective installed manifest (preferably from live inspection per the Phase 1 unit manifest section, falling back to `installed-manifest.json`). | Unit filesystem + `installed-manifest.json` |
| `/status/lease` | Current `execute-lease.json` if one is held, else `{"held": false}`. | `C:\MAST\status\execute-lease.json` |
| `/status/last-run` | The unit-side mirror of `last-run.json`: last completed `execute-mast-provisioning` run with `run_id`, `started_utc`, `ended_utc`, `outcome`, `failed_module`. | `C:\MAST\status\last-execute.json` (new file written by `execute-mast-provisioning.ps1`) |

**Health-check / heartbeat wiring:** `/health` is the heartbeat. It must reflect
the full **provisioning state**, not just "MAST services are running":

- `available: false` (from `availability.json`, with stale-lease recovery applied)
  -> `status: "unavailable"`, HTTP 503 with reason (`maintenance`, `provisioning`,
  `rebooting`, `smoke_failure`).
- An active provisioning lease whose `expires_utc` is in the past -> `status:
  "lease_stale"`, HTTP 503 (the unit is in an inconsistent state and an operator
  or the next driver cycle should clear it).
- `last-run.json` (driver-side) or `last-execute.json` (unit-side) older than
  `2 * scheduled_interval` -> `status: "stale"`, HTTP 200 with `warning` field
  (the unit is reachable but no driver cycle has touched it recently -- this is
  the **unit-visible** version of the Phase 1 driver heartbeat alert).
- Effective payload hash differs from the desired hash published by the prov server
  (when reachable) -> `status: "drift"`, HTTP 200 with `drift: true` so monitors
  can distinguish "broken" from "behind".

**Prometheus alignment:** the same exporter emits the metrics already specified
under **Installed package / manifest exposure** and **Running MAST services
manifest**. Adding `/status/*` routes does not duplicate that data -- it exposes
the structured JSON the provisioning loop already writes, in a form that does not
require Prometheus parsing or WinRM access. The MAST scheduler can poll
`/status/availability` directly instead of `Invoke-Command`-ing into the unit.

**Security:** the endpoint is read-only and bound to the management subnet (same
posture as the metrics scrape path). No state-mutating routes; provisioning still
flows through WinRM.

**Consequence for `availability.json` and the lease:** these files remain the
on-disk source of truth and continue to be written atomically; the HTTP endpoint
is a **reader**, not a parallel writer. Stale-lease and stale-availability rules
defined in Phase 1 are applied at read time so external consumers never see a
state the driver itself would treat as expired.

---

#### Heartbeats and liveness

- **Per-service or per-layer last OK time:** e.g. `mast_heartbeat_timestamp_seconds{component="..."}`
  updated when smoke checks pass, or `time() - mast_last_success_timestamp_seconds` as a
  recording rule for **staleness**.
- **Provisioning loop:** On the prov server, expose **last successful autonomous run**,
  **per-unit last outcome** (`OK`, `SKIP`, `FAIL`, `UNREACHABLE`), and **last failure
  reason** as bounded labels or parallel info metrics.
- **Scheduler / availability:** Integrate with `availability.json` via metrics such as
  `mast_unit_available` and timestamps for last change. The same data is exposed in
  JSON form on `/status/availability` (see **Unit state via HTTP endpoint** above) so
  the MAST scheduler can read it without WinRM, and `/health` rolls availability,
  lease, and last-run age into a single 200/503 heartbeat that external monitors can
  poll without parsing metrics.

**Alerting:** Prometheus Alertmanager rules should fire when scrape fails (`up == 0`),
heartbeat age exceeds threshold, critical `mast_service_up == 0`, or effective payload
hash differs from desired for longer than a grace period after a known deploy.

#### Central command dashboard (Grafana or equivalent)

The **primary** operations UI:

- **Fleet row:** all units, green/yellow/red from heartbeats, availability, and last prov
  outcome.
- **Drill-down:** per-unit panels for **manifest** (hash, modules), **services grid**,
  **heartbeats**, **recent prov events**.
- **Package timing panels:** heatmap of install duration per module across recent runs;
  per-unit package status table (green/red per module from `mast_pkg_last_outcome`);
  fleet-wide p50/p95 trend lines per module. See **Package installation timing and
  statistics** above for the full panel list.
- **Prov server:** panels for scheduler health, LFS/git freshness if exposed, aggregate
  failure rates, and package timeout counter trends.

Document **standard dashboard UIDs**, template variables (`hostname`, `site`, `module`),
and which metrics are **SLI**-grade.

#### Relation to logs

Logs (`activity.csv`, `package-timings.csv`, remote-run transcripts, prov run logs)
remain the **deep dive** for incidents. Prometheus and the central dashboard provide
**continuous, queryable, alertable** summaries; they do not replace structured logging.

---

## Rollout Steps

| # | Task | Status |
|---|------|--------|
| 1 | Replace `execute.lock` with lease record at `C:\MAST\status\execute-lease.json` (TTL, run_id, atomic rename, stale recovery, 60s renewal) | **[DONE]** |
| 1a | Extend `availability.json` writers with mandatory `expected_return_utc` and `lease_owner`; add `AVAIL_STALE_RECOVER` path in `check-and-provision.ps1` | **[DONE]** |
| 1b | Prov-server heartbeat: write `C:\MAST\status\last-run.json` at every cycle exit; emit 60s in-cycle progress lines so a hung driver is distinguishable from a slow one | **[DONE]** |
| 2 | `payload_hash` generation in `build-mast.ps1` -> write `build-manifest.json` with git ref fields | **[DONE]** |
| 3 | Unit-side effective state: inspection-based probe (or hardened `installed-manifest.json`) | **Phase 1** |
| 4 | Per-module uninstall/reinstall paths; `build-mast.ps1` support for pinned git refs and rollback | **Phase 2** |
| 5 | Migrate `check-and-provision.ps1` to non-elevated WinRM Basic + SMB pull transfer (retire `Copy-Item -ToSession`; provision share credentials) | **[DONE]** |
| 6 | Confirm `git lfs pull` works on prov server (deploy key or stored credential) | **Phase 1** |
| 7 | Task Scheduler trigger (or service wrapper) on the prov server | **[PARTIAL]** - installer script exists; task not yet active |
| 8 | Manual dry-runs (`check-and-provision.ps1 -DryRun`) to validate discovery + hash logic | **Phase 1** |
| 9 | Enable live runs; monitor logs / CSV for a week before treating as production | **Phase 3** |
| 10 | Prometheus scrape targets on units and prov server; wire Grafana dashboards and Alertmanager | **Phase 3** |
| 11 | Install and harden OpenSSH Server on fleet units; document firewall, auth, and smoke checks | **Phase 2** |
| 12 | Introduce `unit-profiles.json` (or `profiles/`) and migrate `unit-registry.json` entries to reference a profile; remove duplicated `modules` arrays; support `modules_add` / `modules_remove` overrides | **Phase 2** |
| 13 | DRY the staging area: stage shared payloads once per profile/content hash instead of per-host; add `STAGING_PRUNE` cleanup of unreferenced staged content | **Phase 2** |
| 14 | Unit-side HTTP status/health endpoint (`/health`, `/status/availability`, `/status/manifest`, `/status/lease`, `/status/last-run`) wired to provisioning state files; MAST scheduler reads availability over HTTP instead of WinRM | **Phase 3** |
| 15 | Add `windows-exporter-monitoring` provider module; open scrape port to monitoring subnet; enable textfile collector | **Phase 3** |
| 16 | Add `mast-exporter` provider module (or `mast-textfile-writer` scheduled-task module) emitting `mast_payload_hash`, `mast_module_version_info`, `mast_unit_available`, `mast_pkg_*`, and hosting `/status/*` + `/health` | **Phase 3** |
| 17 | Add `log-shipper` provider module (Promtail / Fluent Bit / Elastic Agent -- fleet-level choice) tailing NSSM stdout/stderr to central log store | **Phase 3** |
| 18 | Add `ntp-sync` provider module with drift smoke check; resolves clock-skew open question | **Phase 1** |
| 19 | Add `pswindowsupdate` provider module (prereq for Phase 2 Windows Update orchestration; also feeds update-pending metrics) | **Phase 2** |
| 20 | `server/install-observability.ps1` on the prov server: install windows-exporter-monitoring + `prov-server-exporter` reading `last-run.json`, `activity.csv`, `package-timings.csv` | **Phase 3** |
| 21 | Provision Prometheus + Grafana + Alertmanager (+ Loki if log-shipper uses it); commit dashboard JSON and alert rules to the repo; document standard dashboard UIDs and template variables | **Phase 3** |

---

## Open Questions

- **Git credential on prov server:** how are LFS credentials stored securely? (Windows
  Credential Manager, deploy key, PAT in vault?)
- **Network discovery vs hostname registry:** should units self-register (e.g. on boot
  send a UDP beacon), or is the hostname-only `unit-registry.json` sufficient for the
  expected unit count?
- **Rollback:** if provisioning fails on a unit, what is the recovery path? (Re-run from
  last known-good snapshot, or just retry next cycle?)
- **Concurrency:** provision units sequentially or in parallel? Parallel is faster but
  harder to debug; sequential is safer for a small fleet.
- **LFS quota exhaustion:** GitHub LFS bandwidth is metered. What is the policy if the
  prov server hits the quota mid-cycle? (Cache LFS objects locally on the prov server
  so cycles do not re-pull on every build; mirror the LFS store to an internal artifact
  cache; pay for additional quota.) The failure mode must be recognizable in logs so
  alerts route differently than a transient build break.
- **Lease/availability TTL semantics:** what `expected_return_utc` value should
  `check-and-provision.ps1` write when entering the `provisioning` state -- a fixed
  conservative cap (e.g. now + 2 h), or a value derived from recent successful run
  durations in `activity.csv`? The MAST scheduler needs a defined grace before it can
  treat a stuck `available: false` as stale.
- **Driver self-monitoring:** the autonomous loop on the prov server is itself a
  long-lived process. If `check-and-provision.ps1` (or its scheduled-task wrapper) hangs
  -- not crashes -- there is currently nothing to detect that. Phase 3 alerting should
  cover "no `RUN_END` in N expected cycles" and not only per-unit outcomes.
- **Clock skew between prov server and units:** maintenance window logic uses unit-local
  time computed from the registry `timezone` field, but `activity.csv` timestamps and
  `availability.json` `since_utc` are written from the prov server. If unit and prov
  server clocks drift (no NTP), maintenance-window decisions and lease TTLs disagree.
  Define an authoritative clock (prov server) and require unit NTP sync as a smoke check.
- **Expand `why_not_operational` error messages with more information.** The current
  strings produced by unit-side components (mount, focuser, covers, stage, imagers,
  PHD2, power switch, etc.) when reporting `why_not_operational` are typically short
  tags like `"not connected"` or `"not safe"`, which is enough for a human glancing at
  a status panel but not enough for the autonomous prov server (or a remote operator
  reading `availability.json` / `/status/availability`) to decide *what to do next*.
  Each `why_not_operational` entry should carry: (a) the component name, (b) a stable
  machine-readable reason code, (c) a human-readable detail string with the underlying
  cause (driver error text, last exception message, timeout value, missing dependency,
  etc.), and (d) where applicable, the timestamp of the observation and any relevant
  IDs (COM port, ASCOM ProgID, device serial). The unit's HTTP `/status/availability`
  endpoint (Phase 3, item 14) should surface this expanded structure so the prov
  server can distinguish "transient -- retry next cycle" from "needs human / hardware
  intervention" without scraping logs.
