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

The per-unit `modules` array is the seed for future profile-based provisioning: different
units can already receive different module sets by editing their registry entry. See
**Unit profiles (future hardware variation)** in Phase 2 for the fuller design.

#### 2. Build Manifest (`build-manifest.json`) **[DONE]**

Written by `build-mast.ps1` after a successful build. Contains a content hash (or version
tag) for the staged payload so units can compare what they have installed against what's
current.

```json
{
  "built_at": "2026-05-05T12:00:00Z",
  "git_sha": "abc1234",
  "payload_hash": "<sha256 of commands.json + all asset checksums>",
  "modules": ["python", "ascom", "cygwin", "mast", "..."],
  "module_versions": {
    "python":  "3.12.0",
    "ascom":   "7.1.0",
    "cygwin":  "3.5.3",
    "mast":    "abc1234",
    "mongodb": "7.0.8"
  }
}
```

`build-mast.ps1` writes this to `staging\<hostname>\build-manifest.json` at build time.
The `module_versions` map is populated from the `version` field in each provider's
`module.json`. It is the authoritative record of what version of each package was staged
for a given build, and is carried through to `installed-manifest.json` on the unit after
a successful provisioning run. This makes it possible to answer "what version of python
is on mast03?" without logging into the unit, and to correlate timing regressions or
failures with specific version bumps.

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
`check-and-provision.ps1` every 30 minutes under SYSTEM. The task has **not** been
installed and activated on the provisioning server; this is blocked on Phase 1 work
(the driver must be hardened before it runs unattended).

---

### Transfer: Prov Server -> Unit **[PARTIAL]**

`check-and-provision.ps1` currently uses `Copy-Item -ToSession` (WinRM push). This works
in the dev/test environment but requires `TrustedHosts` configuration on the provisioning
server (an elevated operation). **The production mechanism is SMB pull** (see below);
the WinRM push is a dev-only shortcut to be retired.

**Production transfer: unit pulls from prov server SMB share**

The provisioning server exposes `\\<prov-server>\mast-staging` as an SMB share (created
by `build-mast.ps1`). The orchestrator sends a short WinRM command to the unit triggering
`net use` + `robocopy` (or `xcopy`) to pull the staged payload. No credential forwarding
or CredSSP is required on the unit side; the share credential is passed explicitly in the
`net use` call.

**Credential handling:** the SMB share requires authenticated access. The provisioning
service account credentials (or a dedicated read-only share account) must be stored
securely on the unit side or passed at call time via the WinRM command. This is more
involved than a public HTTP endpoint but avoids the double-hop problem and keeps the
prov server's WinRM client unprivileged.

**Required setup on prov server:**
- SMB share `mast-staging` pointing at the staging output directory (already created by
  `build-mast.ps1` when not run with `-SkipSmbShare`).
- Share and NTFS permissions scoped to the unit service account or a dedicated
  `mast-transfer` account.
- Firewall rule allowing TCP 445 inbound from the unit subnet.

Migration from `Copy-Item -ToSession` to SMB pull is tracked under **Phase 1 -
Provisioning server privilege model**.

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

3. **Large payload delivery (`staging/` artifacts)** uses **SMB pull**: the unit connects
   to `\\<prov-server>\mast-staging` and copies its payload using `net use` + `robocopy`.
   The orchestrator sends only a short WinRM command to trigger the pull; no credential
   forwarding or CredSSP is required on the provisioning server side. See **Transfer:
   Prov Server -> Unit** for share setup and credential handling.

4. **`check-and-provision.ps1` today** uses **`New-PSSession`** and
   **`Copy-Item -ToSession`**. **Migration requirement:** replace the push transfer with
   an SMB pull triggered via a short WinRM command, and migrate remote control commands
   to **WinRM Basic HTTP** (same model as `run-remote-script-winrm.py`). The target end
   state is **non-elevated service + hostname-based WinRM Basic + SMB pull transfer**.

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

#### 1. SMB share bypassed in dev/test

- **Current exception:** `build-mast.ps1` can run non-elevated with `-SkipSmbShare` (and
  `check-and-provision.ps1` passes it by default), falling back to WinRM
  `Copy-Item -ToSession` push.
- **Why it's a blocker:** production transfer is SMB pull. The share must exist, be
  permissioned, and be reachable from the unit. `-SkipSmbShare` must not be used in
  production runs.
- **Exit criteria:** `build-mast.ps1` always creates the SMB share in production mode;
  share account credentials are provisioned and stored securely; `check-and-provision.ps1`
  triggers SMB pull via a short WinRM command instead of pushing via `Copy-Item -ToSession`.

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
hardware-specific configuration exists.

**Future requirement:** As the fleet grows, hardware may diverge -- different camera
models, mount types, focusers, or other attached instruments. When that happens, a single
flat module list per unit will not be sufficient; the provisioning system must be able to
assign a **profile** to each unit that determines which packages are installed, which
configuration values are applied, and which smoke checks are expected.

**Design constraints to keep in mind now** (no implementation required today):

- The `modules` array per unit in `unit-registry.json` is already the right primitive.
  Do not collapse it into a fleet-wide default that every unit inherits -- per-unit
  module lists must remain first-class.
- A future `profile` field (e.g. `"profile": "standard-scope"`) could map to a named
  module set and configuration block defined elsewhere, so `unit-registry.json` stays
  concise while the profile definition lives in a separate file.
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
| 1 | Replace `execute.lock` with lease record (TTL, run_id, atomic rename, stale recovery) | **Phase 1** |
| 2 | `payload_hash` generation in `build-mast.ps1` -> write `build-manifest.json` with git ref fields | **[DONE]** |
| 3 | Unit-side effective state: inspection-based probe (or hardened `installed-manifest.json`) | **Phase 1** |
| 4 | Per-module uninstall/reinstall paths; `build-mast.ps1` support for pinned git refs and rollback | **Phase 2** |
| 5 | Migrate `check-and-provision.ps1` to non-elevated WinRM Basic + SMB pull transfer (retire `Copy-Item -ToSession`; provision share credentials) | **Phase 1** |
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
