# Autonomous Provisioning Design Sketch

> **Document status:** This document is organized into three delivery phases plus a
> **Foundation** section for building blocks that are already implemented. Sections marked
> **[DONE]** reflect the current codebase state. **[PARTIAL]** means scaffolding exists
> but the feature is not complete. Unmarked items under each phase are the remaining work
> to converge toward.
>
> **Important:** The codebase currently has scripts that can perform provisioning steps
> when invoked manually. It does **not** yet have a working autonomous loop -- no
> self-scheduling service, no unattended cadence, no production-hardened driver. That is
> the primary goal of Phase 1.

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

**Automated lab mapping (this repo):** run **`tools/sync-dev-unit-hosts.ps1`** in an
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

#### 2. Build Manifest (`build-manifest.json`) **[DONE]**

Written by `build-mast.ps1` after a successful build. Contains a content hash (or version
tag) for the staged payload so units can compare what they have installed against what's
current.

```json
{
  "built_at": "2026-05-05T12:00:00Z",
  "git_sha": "abc1234",
  "payload_hash": "<sha256 of commands.json + all asset checksums>",
  "modules": ["python", "ascom", "cygwin", "mast", "..."]
}
```

`build-mast.ps1` writes this to `staging\<hostname>\build-manifest.json` at build time.

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

The script exists and can perform provisioning steps when invoked manually. It is **not**
yet a hardened autonomous driver: it has not been validated end-to-end against a real unit,
the transfer mechanism requires elevated WinRM client config (see Phase 1), and the
maintenance window logic is not enforced. The intended control flow once Phase 1 is
complete:

```
for each unit in unit-registry.json:
  1. Ping / WinRM reachability check
     - unreachable -> log warning, skip, continue to next unit

  2. Build latest payload for this unit
     - run build-mast.ps1 -HostName <hostname>
     - reads build-manifest.json from staging output

  3. Query the unit's installed-manifest.json via WinRM
     - if payload_hash matches -> log "up to date", skip

  4. Transfer staging payload to unit via WinRM
     - Invoke-Command + Copy-Item -ToSession

  5. Execute provisioning on unit
     - Invoke-Command -> execute-mast-provisioning.ps1

  6. Verify smoke tests
     - check C:\MAST\logs\smoke\*-smoke.txt on unit

  7. Log result (activity.csv + session log)
```

#### 5. Scheduling **[PARTIAL]**

`server/install-scheduled-task.ps1` exists and can register a Task Scheduler job to run
`check-and-provision.ps1` every 30 minutes under SYSTEM. The task has **not** been
installed and activated on the provisioning server; this is blocked on Phase 1 work
(the driver must be hardened before it runs unattended).

---

### Transfer: Prov Server -> Unit **[PARTIAL]**

`check-and-provision.ps1` currently uses `Copy-Item -ToSession` (WinRM push). This works
in the dev/test environment but requires `TrustedHosts` configuration on the provisioning
server (an elevated operation -- see Phase 1).

**Options for production:**

- **Option A**: CredSSP on prov server (`Enable-WSManCredSSP -Role Client`) -- allows
  credential delegation; unit receives pushes via `Copy-Item -ToSession`.
- **Option B (recommended)**: Unit pulls from prov server's SMB share (reverse direction,
  no double-hop) -- prov server exposes `\\prov-server\mast-staging`; unit runs
  `net use` + `xcopy` triggered via a short WinRM command.
- **Option C**: Unit pulls via HTTP from prov server.

Migration to Option B is tracked under **Phase 1 - Provisioning server privilege model**.

---

### Version / Drift Detection **[PARTIAL]**

The logic is present in `check-and-provision.ps1` but only exercised by manual invocation.
It becomes meaningful once the autonomous loop is running.

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

**Mechanism:** `C:\ProgramData\MAST\status\availability.json`

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
   typically requires **administrator** rights on the **provisioning server**. This is the
   current behavior of `check-and-provision.ps1` and must be migrated.

2. **Target approach for remote execution and script transfer without elevating the prov
   server:** use **WinRM over HTTP (5985) with Basic authentication**, the same surface
   enabled by `client/bootstrap-winrm.ps1` on the unit. From Python, **`pywinrm`** issues
   SOAP to `http://<hostname>:5985/wsman` and does **not** depend on local `TrustedHosts`
   or `Enable-PSRemoting` on the orchestrator machine. This repo already includes
   **`tools/run-remote-script-winrm.py`** for this purpose.

3. **Large payload delivery (`staging/` artifacts)** should follow a **reverse pull** or
   **already-open share** model:
   - **Unit pulls** via **HTTP** or **SMB** from the provisioning server; orchestrator
     only sends a **short** remote command (achievable via `pywinrm`).
   - Avoid requiring **CredSSP** or machine-wide **TrustedHosts** on the server unless
     explicitly accepted as an operational cost.

4. **`check-and-provision.ps1` today** uses **`New-PSSession`** and
   **`Copy-Item -ToSession`**. **Migration requirement:** either migrate this driver to
   **Basic HTTP WinRM** (same auth model as `run-remote-script-winrm.py`) plus pull-based
   file transfer, or document and automate **one-time** elevated server prep -- but the
   **target end state** is **non-elevated service + hostname-based WinRM Basic + pull or
   chunked transfer**.

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
- A **lease record** under `C:\ProgramData\MAST\status\` written **atomically** (temp file
  then rename), carrying **TTL**, **run_id**, **started_utc**, and optional **held_by**
  identity so the sole provisioning server can **poll**, **expire stale leases**, or follow
  a break-glass procedure without guessing.

Whatever replaces the lock must: **prevent overlapping installs**; **recover without manual
SSH or RDP** after typical failure modes; remain correct when **only one** provisioning
machine drives automation; and expose enough state for **logs and metrics**.

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

### Maintenance window enforcement in `check-and-provision.ps1`

`unit-registry.json` already carries `maintenance_window` and `timezone` per unit. The
driver must **enforce** these windows: disruptive steps (update transfers, reboots, Windows
Update installs) must be skipped outside the window with a `MAINT_SKIP` log event.

**Planned parameters for `check-and-provision.ps1`:** `-MaintenanceWindowStart` and
`-MaintenanceWindowEnd` (24-hour local time, e.g. `10` and `16`). Runs that start outside
the window skip update and reboot steps and log:

```
[2026-05-06T22:30:00Z] MAINT_SKIP unit=mast02 reason=outside_window current=22:30 window=10:00-16:00
```

Non-disruptive steps (hash check, skip-if-current) may run at any time.

---

### Test-mode exceptions (blockers before production)

While stabilizing the end-to-end flow against a disposable VirtualBox VM, the repo relies
on several **test-mode exceptions**. These must be eliminated before the autonomous
provisioning system is declared production-ready for physical units.

#### 1. No SMB share required (dev/test)

- **Current exception:** `build-mast.ps1` can run non-elevated with `-SkipSmbShare` (and
  `check-and-provision.ps1` passes it by default), relying on WinRM `Copy-Item -ToSession` push.
- **Why it's a blocker:** production may still need an alternate transfer mode (SMB pull,
  BITS/robocopy, etc.) for large fleets or when WinRM copy is slow/fragile.
- **Exit criteria:** choose and harden the production transfer mechanism; remove reliance
  on "non-elevated build" as an implicit assumption.

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

### Package lifecycle, MAST version pinning, rollback, and observability

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
- `EXECUTE_START` / `EXECUTE_OK` / `EXECUTE_FAIL` bracket the long-running provisioning
  step so you can see exactly where time is spent.
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
- **Per-module signals:** `mast_module_present{module="..."} == 1`, optional
  `mast_module_version_info{module="...", version="..."} == 1` where versions are known.
- **Drift vs build:** If the prov server publishes the **current** `build-manifest` hash
  for that unit's module set, the dashboard can compare **effective** vs **desired**
  in one place.

Goal: the central dashboard shows a **table or stat panel per unit**: expected vs effective
hash, module checklist, and age of last successful alignment.

#### Running MAST services manifest

Enumerate MAST-related Windows services and expose **running / stopped / missing** in a
scrape-friendly form:

- `mast_expected_service{service="..."} == 1` paired with `windows_service_state` from
  windows_exporter, or
- Custom `mast_service_up{service="..."}` (1 when Running and expected, 0 otherwise).

Include **start mode** where useful (Automatic vs Manual) so misconfiguration is visible.

#### Heartbeats and liveness

- **Per-service or per-layer last OK time:** e.g. `mast_heartbeat_timestamp_seconds{component="..."}`
  updated when smoke checks pass, or `time() - mast_last_success_timestamp_seconds` as a
  recording rule for **staleness**.
- **Provisioning loop:** On the prov server, expose **last successful autonomous run**,
  **per-unit last outcome** (`OK`, `SKIP`, `FAIL`, `UNREACHABLE`), and **last failure
  reason** as bounded labels or parallel info metrics.
- **Scheduler / availability:** Integrate with `availability.json` via metrics such as
  `mast_unit_available` and timestamps for last change.

**Alerting:** Prometheus Alertmanager rules should fire when scrape fails (`up == 0`),
heartbeat age exceeds threshold, critical `mast_service_up == 0`, or effective payload
hash differs from desired for longer than a grace period after a known deploy.

#### Central command dashboard (Grafana or equivalent)

The **primary** operations UI:

- **Fleet row:** all units, green/yellow/red from heartbeats, availability, and last prov
  outcome.
- **Drill-down:** per-unit panels for **manifest** (hash, modules), **services grid**,
  **heartbeats**, **recent prov events**.
- **Prov server:** panels for scheduler health, LFS/git freshness if exposed, and
  aggregate failure rates.

Document **standard dashboard UIDs**, template variables (`hostname`, `site`), and which
metrics are **SLI**-grade.

#### Relation to logs

Logs (`activity.csv`, remote-run transcripts, prov run logs) remain the **deep dive** for
incidents. Prometheus and the central dashboard provide **continuous, queryable, alertable**
summaries; they do not replace structured logging.

---

## Rollout Steps

| # | Task | Status |
|---|------|--------|
| 1 | Replace `execute.lock` with lease record (TTL, run_id, atomic rename, stale recovery) | **Phase 1** |
| 2 | `payload_hash` generation in `build-mast.ps1` -> write `build-manifest.json` with git ref fields | **[DONE]** |
| 3 | Unit-side effective state: inspection-based probe (or hardened `installed-manifest.json`) | **Phase 1** |
| 4 | Per-module uninstall/reinstall paths; `build-mast.ps1` support for pinned git refs and rollback | **Phase 2** |
| 5 | Migrate `check-and-provision.ps1` to non-elevated WinRM Basic + pull-based file transfer | **Phase 1** |
| 6 | Confirm `git lfs pull` works on prov server (deploy key or stored credential) | **Phase 1** |
| 7 | Task Scheduler trigger (or service wrapper) on the prov server | **[PARTIAL]** - installer script exists; task not yet active |
| 8 | Manual dry-runs (`check-and-provision.ps1 -DryRun`) to validate discovery + hash logic | **Phase 1** |
| 9 | Enable live runs; monitor logs / CSV for a week before treating as production | **Phase 3** |
| 10 | Prometheus scrape targets on units and prov server; wire Grafana dashboards and Alertmanager | **Phase 3** |
| 11 | Install and harden OpenSSH Server on fleet units; document firewall, auth, and smoke checks | **Phase 2** |

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
