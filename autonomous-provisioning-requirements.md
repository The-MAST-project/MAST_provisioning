# Autonomous Provisioning Design Sketch

> **Document status:** This is a **design and roadmap**, not a statement of what is finished.
> Many sections describe the **intended steady-state** autonomous loop (scheduled runs, unified
> logging on the prov server, maintenance-window updates, etc.). The repo already contains
> **partial implementations** (`check-and-provision.ps1`, `build-mast.ps1`, module payloads,
> `onboard-mast-unit.ps1`, dev helpers such as `tools/run-remote-script-winrm.py`). Unless a
> sentence explicitly says **implemented today** or points at a specific script path, treat it
> as **target behavior** to converge toward, not a checklist of completed tasks.

## Target outcome (future steady state)

The provisioning server is intended to run **entirely** independently: discover reachable MAST
units on the network, compare their installed state to the latest build, and push updates
without intervention from the Mac host or a separate orchestration process.

**Identity and addressing:** Each unit is identified **only** by its configured Windows hostname (for example `mast01`). The machine **must** be allowed to use **DHCP** for IPv4; operators and automation discover units **by name** (DNS, reverse DNS, or a managed hosts file), not by pinning a fixed address in scripts or `unit-registry.json`. Do not treat an IP as the long-lived identity of a unit.

**Operator SSH access:** Each fleet unit must have an **SSH server installed, configured, and running** in steady state so authorized staff can **remote in interactively** when needed (debugging, recovery, file transfer with familiar tools). This is **complementary** to WinRM used for provisioning automation; see **Fleet SSH server (operator remote access)** below.

---

## Development lab: hostname resolution (simulate internal DNS)

Production units resolve each other and are reached by the provisioning server using **corporate or site DNS** (forward records for `mast01` ... `mast20`). No fixed IP appears in `unit-registry.json`.

On a **developer PC** running VirtualBox with **host-only DHCP**, the guest address changes and hostnames do not resolve until something provides the same name-to-address mapping DNS would supply.

**Automated lab mapping (this repo):** run **`tools/sync-dev-unit-hosts.ps1`** in an **elevated** PowerShell on the **Windows host** (once after the VM has DHCP, or whenever the guest IP changes). The script:

- discovers the guest IPv4 (VirtualBox Guest Additions property when present, otherwise NIC1 MAC vs `Get-NetNeighbor` on the host-only subnet, else a single VirtualBox-style MAC on that subnet),
- inserts a **marked block** into `%SystemRoot%\System32\drivers\etc\hosts` so `[System.Net.Dns]::GetHostAddresses('mast01')` matches production behavior,
- keeps a timestamped backup of `hosts`.

This is **lab-only**. Do **not** rely on it on the **production provisioning server** when real DNS already resolves `mastNN`. Operators should never hand-edit `hosts` for each DHCP renewal in automation; the script is the supported dev substitute.

**Integration hint:** after `vbox-recreate-unit.ps1` reports WinRM up, run `sync-dev-unit-hosts.ps1` so `check-and-provision.ps1`, `run-prov-test.py`, and `Invoke-Command -ComputerName mast01` all see the same hostname contract as in the field.

---

## Provisioning server privilege model (non-elevated operation)

The autonomous loop on the **final provisioning machine** should run under a **normal service account** that is **not** a member of the local Administrators group. That matches least-privilege deployment and avoids requiring interactive elevation on the server.

**Implication:** patterns that depend on **elevating the provisioning server** must not be required for core operation.

1. **PowerShell remoting client (`New-PSSession`, `Invoke-Command`, `Copy-Item -ToSession`)** often assumes the WinRM **client** on the server machine is configured (for example **TrustedHosts** for workgroup targets). Updating machine-wide WinRM client settings typically requires **administrator** rights on the **provisioning server**. Treat this as **legacy / optional** for the autonomous driver until migrated.

2. **Supported approach for remote execution and script transfer without elevating the prov server:** use **WinRM over HTTP (5985) with Basic authentication**, the same surface enabled by `client/bootstrap-winrm.ps1` on the unit. From Python, **`pywinrm`** issues HTTPS SOAP to `http://<hostname>:5985/wsman` and does **not** depend on local `TrustedHosts` or `Enable-PSRemoting` on the orchestrator machine. This repo includes **`tools/run-remote-script-winrm.py`**, which uploads a `.ps1` in **small chunks** (WinRM command-length limits) and runs it on the unit with process-scope execution policy bypass -- suitable for ad hoc remote steps from an **unprivileged** account.

3. **Large payload delivery (`staging/` artifacts)** should follow a **reverse pull** or **already-open share** model so the orchestrator does not need admin-only WinRM client tuning:
   - **Unit pulls** via **HTTP** or **SMB** from the provisioning server (see **Transfer: Prov Server -> Unit** below); orchestrator only sends a **short** remote command ( achievable via `pywinrm` or a thin helper).
   - Avoid requiring **CredSSP** or machine-wide **TrustedHosts** on the server unless explicitly accepted as an operational cost.

4. **`check-and-provision.ps1` today** uses **`New-PSSession`** and **`Copy-Item -ToSession`**. **Retention requirement:** when hardening the final configuration, either **migrate** this driver to **Basic HTTP WinRM** (same auth model as `run-prov-test.py`) plus pull-based file transfer, or document and automate **one-time** elevated server prep -- but the **target end state** is **non-elevated service + hostname-based WinRM Basic + pull or chunked transfer**, aligned with physical deployment.

---

## Architecture Overview (target)

```
Provisioning Server (Windows, long-lived)
  |
  |-- Windows Task Scheduler / NSSM service
  |     runs: check-and-provision.ps1  (every N minutes)
  |
  |-- build-mast.ps1          (existing, unchanged)
  |-- check-and-provision.ps1  (exists; extended behavior below is target)
  |-- unit-registry.json      (discovery: units to contact — no cached per-unit installed state)
  |
  +-- WinRM --> MAST Unit 1 (mast01)
  +-- WinRM --> MAST Unit 2 (mast02)
  +-- WinRM --> MAST Unit N (mastN)
  |
  +-- SSH (optional path for operators) --> same units when enabled
```

No Mac host involvement at runtime. The Mac is only used to:
- Push git commits (new module versions, assets via lfs)
- Review logs

---

## Fleet SSH server (operator remote access) (**target**)

**Requirement:** Every MAST unit in the fleet must ship with an **SSH server** enabled for
steady-state operation: installed, configured for site policy (listen address, port, allowed
users or groups), set to **start automatically** with the OS, and **running** so operators can
`ssh` to `mastNN` by hostname when the network path allows. Provisioning automation remains on
**WinRM**; SSH is for **human-driven** remote shells and tooling, not a replacement for the
autonomous control plane unless explicitly extended later.

**Windows:** Use the platform **OpenSSH Server** optional capability (or equivalent supported
distribution), harden host keys and `sshd_config`, and restrict access with **firewall rules**
(for example allow TCP 22 only from management subnets or jump hosts). Document the **expected
smoke check** (for example: service `sshd` Running, port reachable from a defined bastion) so
**Observability** can treat SSH availability like other fleet services.

**Security:** Key-based auth, deny-password where policy allows, patch cadence aligned with
Windows Update, and no overlap with insecure bootstrap shortcuts. SSH must not weaken the
steady-state posture described under **Test-mode exceptions** for WinRM HTTPS.

---

## Unit provisioning manifest (source of truth)

Each **unit machine** owns and manages its own provisioning state. The provisioning server must
**not** cache or persist per-unit manifest contents (or a replica of “what is installed”) on
the host. The registry on the prov server should hold only **discovery and scheduling
metadata** — hostnames, maintenance windows, module lists used to **build** payloads —
not a mirrored copy of each unit’s installed state that could go stale.

**Derived state, not a parallel ledger:** it is preferable that the unit **not** treat a static
on-disk manifest file (for example `installed-manifest.json`) as the sole source of truth.
Instead, when probed, the unit should **compute** a manifest from the actual contents of the
machine: installed paths, file hashes or versions where applicable, service state, and other
checksums that reflect what is really present. A probe then always reports current reality,
including after manual repair, partial installs, or external changes.

**Why:** keeping manifest text on the host, or a manifest file on the unit that is updated on a
different timeline than the filesystem, creates **sync drift** — the orchestrator believes a
unit matches `build-manifest.json` when the machine does not, or vice versa. Inspection-based
manifests avoid contradicting the live system when checking whether provisioning is current.

---

## Components

### 1. Unit Registry (`unit-registry.json`)

Tracks known units. Managed manually (add/remove entries when hardware is added/retired). Does
not store per-unit installed manifests or probe results — see **Unit provisioning manifest
(source of truth)**.

```json
[
  {
    "hostname": "mast01",
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

### 3. Installed / effective state (on each unit)

The effective installed state used for drift detection should match the principles in
**Unit provisioning manifest (source of truth)** above: **prefer computing** a manifest (same
shape as `build-manifest.json`, including a comparable `payload_hash` or equivalent) from the
live tree and markers on disk when the prov server queries the unit, rather than trusting a
file that could diverge from reality.

If an `installed-manifest.json` (or similar) is written after provisioning, treat it as an
**optimization or audit artifact**, not the authoritative answer — the comparison logic should
ultimately align with what a fresh inspection of the unit would produce. The provisioning server
compares the **build** manifest’s `payload_hash` to the **effective** hash reported by the
unit’s probe to decide whether an update is needed.

### 4. `check-and-provision.ps1` (prov server driver — **target loop**)

Intended control flow once the autonomous design is fully realized:

```
for each unit in unit-registry.json:
  1. Ping / WinRM reachability check
     - unreachable → log warning, skip, continue to next unit

  2. Build latest payload for this unit
     - run build-mast.ps1 -HostName <hostname>
     - reads build-manifest.json from staging output

  3. Query the unit’s effective provisioning state via WinRM (computed / inspected manifest —
     see **Unit provisioning manifest (source of truth)**)
     - if payload_hash matches → log "up to date", skip

  4. Transfer staging payload to unit via WinRM
     - Invoke-Command + Copy-Item -ToSession  (same-network, no double-hop credential issue
       when prov server uses CredSSP or explicit credential forwarding)
     - alternative: unit pulls via SMB share on prov server

  5. Execute provisioning on unit
     - Invoke-Command → execute-mast-provisioning.ps1

  6. Verify smoke tests
     - check C:\MAST\logs\smoke\*-smoke.txt on unit

  7. Log result to C:\MAST\logs\autonomous-prov.log
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

Non-elevated orchestrators cannot rely on machine-wide WinRM client tweaks on the prov server; prefer **unit pull** or **pywinrm / HTTP Basic** for control-plane commands (see **Provisioning server privilege model** above).

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

1. **Payload hash** — fast check; if the unit’s **effective** `payload_hash` (from inspection /
   computed manifest) equals `build-manifest.payload_hash`, the unit is up to date and no
   action is taken.

2. **Smoke test re-run** — optional deeper check; re-run `verify` steps on the unit even when
   hashes match, to catch runtime drift (service stopped, file deleted, etc.) without a full
   reprovisioning cycle.

---

## Package lifecycle, MAST version pinning, rollback, and observability (**target**)

### Per-package uninstall and reinstall

Upgrades must be **clean**: for each provisioned **package/module**, automation needs **full
control** to **uninstall** and **reinstall** that module alone (or run an equivalent **repair**
that resets the same surface area). Layering new files on top of a broken, partial, or manually
altered install is not acceptable as the only strategy. Module boundaries should expose **paired**
operations suitable for scripting — install, uninstall or teardown, then install again — so the
fleet can recover from corruption and so major version jumps do not inherit stale registry keys,
services, or paths.

### Pinning and rolling MAST services by git tag or commit

**Desired vs accidental drift:** Deployments must not depend solely on “whatever the prov server
checkout built last.” **MAST-owned services and payloads** must be updatable and rollable against
explicit **git identity**: a **tag** (release) and/or **commit hash** recorded in `build-manifest.json`
(and echoed in **effective** inspected state on the unit).

**Operational contract:**

- `build-mast.ps1` (and any prerequisite **git checkout / fetch** step on the prov server) must
  support targeting a **pinned ref** so staged artifacts correspond to a **known** revision.
- **Rollback** is **deploying a prior ref** through the same pipeline (build → transfer → execute),
  subject to schema/data compatibility and operator policy — not ad hoc file swaps on the unit.
- Drift detection compares **effective** identity on the machine (from inspection) to the
  **intended** ref for that rollout, aligned with **Version / Drift Detection** above.

Pinning parameters may surface as flags, config on the prov server, or optional fields in
**discovery metadata** (for example per-unit or fleet-wide **target ref**), but the prov server
still does **not** store a cached copy of **what is installed** — only what **should** be built
for the next action.

### Full observability without caching machine state on the prov server

The fleet still requires **full observability** (logs, metrics, dashboards — see **Observability**).
That does **not** relax **Unit provisioning manifest (source of truth)**: the provisioning server
must **not** persist per-unit installed manifests or probe snapshots as an orchestration ledger.

**How both hold:**

- **Truth for control plane decisions** comes from **fresh** probes each cycle (and/or scrape
  targets that read live state on the unit), compared to the **build** produced for that run.
- **Monitoring systems** (Prometheus time series, log aggregation) store **history for humans and
  alerts**; that is **telemetry**, not the authoritative “installed state” database for
  `check-and-provision`. Avoid duplicating “current manifest” rows on the prov server **for
  automation** — use live inspection or metrics emitted **from** the unit.

---

## Observability

This section mixes **implemented** tooling (for example `run-remote-script-winrm.py`) with
**planned** logging and metrics for the future autonomous prov-server loop.

**Fleet visibility target:** In addition to logs and CSV on the prov server, the **installed
software manifest**, the **set and health of MAST-related Windows services**, and **component
heartbeats** must be **machine-readable and scrapeable** (Prometheus-compatible exposition)
so a **central command dashboard** (for example Grafana backed by Prometheus) shows fleet
state at a glance. Ad hoc WinRM or RDP should not be the primary way to answer "what is on this
box?" or "is the stack alive?" See **Package lifecycle, MAST version pinning, rollback, and
observability** for how this coexists with **no cached per-unit manifest on the prov server**.

### Remote one-off scripts (`tools/run-remote-script-winrm.py`) — **implemented**

Orchestrators can invoke ad hoc `.ps1` files on the unit via WinRM HTTP + Basic (chunked upload).
Those runs should be **correlatable** with server-side logs and **inspectable** later for health checks.

**On each run the guest sets:**

| Variable | Meaning |
|----------|---------|
| `MAST_RUN_ID` | Correlation id (pass `--run-id` or auto-generated hex). |
| `MAST_REMOTE_INVOKER` | Literal `run-remote-script-winrm.py`. |
| `MAST_REMOTE_SCRIPT_REPO` | Repo-relative script path (forward slashes). |
| `MAST_REMOTE_SCRIPT_PATH` | Full path to the staged temp `.ps1` on the unit. |
| `MAST_REMOTE_LOG_ROOT` | Folder for this tool’s transcript + JSON (same as `mastLogRoot`; typically `C:\MAST\logs\remote-runs`). |

**On-disk artifacts (unit):**

| Path pattern | Content |
|--------------|---------|
| `<SystemDrive>\MAST\logs\remote-runs\remote-<ComputerName>-<run_id>.log` | `Start-Transcript` capture (unless `--no-remote-transcript`). Usually `C:\MAST\logs\remote-runs\...`. |
| `<SystemDrive>\MAST\logs\remote-runs\remote-<ComputerName>-<run_id>.json` | Machine-readable summary (`kind: mast_remote_run`, exit_code, duration_ms, transcript path, optional error). |

**Stdout markers:** lines beginning with `##MAST##` are emitted at **remote_run_start**, **remote_run_end**, and on PowerShell **catch** (**remote_error**). The Python driver mirrors every `##MAST##` line to **stderr** on the orchestrator with a `[guest]` prefix so operators can `grep` without parsing full WinRM XML.

**Orchestrator artifact:** optional `--write-local-meta PATH` writes a small JSON record on the machine running Python (host, run_id, status_code, duration) for CI or auditing.

**Startup wait:** `run-remote-script-winrm.py` loops until TCP **5985** is open and WinRM accepts Basic auth (defaults: `--wait-winrm-seconds 900`, `--wait-winrm-poll-seconds 5`). Use **`--wait-winrm-seconds 0`** for fail-fast when the unit is already up.

**Convention for custom scripts:** emit occasional `Write-Host "##MAST## kind=phase phase=<name> ..."` lines for long phases (similar to prov-server `EVENT_TYPE` tokens). Prefer reading **`$env:MAST_RUN_ID`** when appending logs (remote-run transcripts live under **`C:\MAST\logs\remote-runs\<timestamp>_<run_id>\`** on typical installs; module provisioning uses **`C:\MAST\logs\sessions\<timestamp>\`** plus **`C:\MAST\logs\smoke`** and **`C:\MAST\logs\verify`**).

**Caveat:** if a child script calls **`exit`** in the same WinRM runspace, the wrapper’s `finally` may not run; WinRM `status_code` and partial transcript / JSON may still be missing. Prefer **`throw`** or non-terminating flow for clean summaries.

**Hang after remote script “Done”:** `Enable-PSRemoting` / rebuilding the HTTPS listener can recycle the WinRM service and drop the **same** WinRM session your orchestrator is using; the guest transcript may finish while the client waits forever. **`prepare-mast-client.ps1`** avoids calling **`Enable-PSRemoting`** mid-session when **`MAST_RUN_ID`** is set (from `run-remote-script-winrm.py`) and listeners already exist, and it defers **HTTPS listener creation** (the `winrm.cmd` path) to the **last** step. Immediately before that step it prints **`##MAST## kind=prepare_safe_complete ...`** so the orchestrator log shows a clear boundary (orchestrators that only stream output at the end of the WinRM call may still not see it until the response completes—see TODO below).

**Hang with guest transcript complete but no `remote_run_end` / Python never returns:** the wrapper used to call **`Stop-Transcript`** in **`finally`** after your `.ps1` ran; under WinRM that call can block indefinitely even when the child script finished, so the SOAP response never completes. **`run-remote-script-winrm.py`** no longer calls **`Stop-Transcript`**; **`Start-Transcript`** output is finalized when the remote PowerShell process exits right after **`##MAST## kind=remote_run_end`** and the JSON summary are written.

**TODO — robust remote handshake (orchestrator):** Teach `run-remote-script-winrm.py` (or a follow-on tool) to treat **`prepare_safe_complete`** as a completion milestone: e.g. stream **stdout** during the long WinRM invoke, **exit 0** (or open a **fresh** WinRM call only for the HTTPS step) once that marker is seen, instead of blocking until the single SOAP response finishes—so a subsequent WinRM recycle does not hold the primary client. Until then, deferring listener recreation to the end plus **`prepare_safe_complete`** is a pragmatic compromise.

### Log files on the prov server (`C:\MAST\logs\prov\`) — **target layout**

Planned structure once the autonomous loop logging described here is fully wired up (today’s
behavior may differ; see `server/check-and-provision.ps1` and existing logs on disk).

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

### Progress visibility during long operations (**planned**)

Long-running phases (transfer, execute) would write heartbeat lines every 30 seconds:

```
[2026-05-05T14:09:00Z] TRANSFER_PROGRESS  unit=mast02 files_done=28/41 bytes_done=950000000/1362534400
[2026-05-05T14:30:00Z] EXECUTE_PROGRESS   unit=mast02 elapsed_s=1244 last_module=mongodb
```

**Target:** `execute-mast-provisioning.ps1` would write per-module progress to a sidecar file
such as `C:\MAST\logs\prov\execute-progress.txt` on the unit, which the prov server
would poll via WinRM during execution and relay into the run log.

### Windows Event Log integration (**planned**)

Each `RUN_END` would write a single Windows Event Log entry (source: `MAST-Provisioning`,
Event ID 1000=OK, 1001=partial failure, 1002=run error), so monitoring agents (Zabbix,
Datadog, etc.) could pick up outcomes without parsing log files.

### Alerting (**planned**)

The design calls for `check-and-provision.ps1` to accept an optional `-AlertEmail` parameter.
If set, it would send a plain-text summary via `Send-MailMessage` when any unit ends `FAIL` or
`UNREACHABLE`. Subject line example: `[MAST] Provisioning alert: mast02 FAIL (smoke:ascom)`.
No email on all-OK or all-SKIP runs.

### Prometheus scrape targets and central command dashboard (**target**)

Operators and automation must be able to see **fleet-wide** answers without logging into each
unit: what payload/modules are effective, which MAST services are running, and whether each
layer last reported healthy. That state must be **scraped by Prometheus** (or a compatible
pull-based collector) and rendered clearly on a **central command dashboard** used as the
primary operations view.

#### Principles

1. **Pull model:** Prometheus scrapes **HTTP(S)** endpoints on a documented interval. Units and
   the provisioning server participate as **first-class scrape targets** on the monitoring
   network (not only as files that a human opens after the fact).
2. **Same truth as provisioning:** Metrics and labels that describe **installed payload hash**,
   **module versions**, and **drift** must align with the **effective** manifest described under
   **Unit provisioning manifest (source of truth)** so the dashboard never contradicts
   `check-and-provision` decisions.
3. **Low-cardinality labels:** Use stable label keys (`hostname`, `site`, `module`, `service`,
   `component`). Avoid unbounded label values (full file paths, raw error stacks); put detail in
   logs or separate info metrics with bounded cardinality.
4. **Security:** Scrape paths reachable only from the monitoring segment; prefer TLS and auth
   where site policy requires it.

#### Implementation patterns (non-prescriptive)

Pick one or combine as needed, as long as the result is Prometheus-scrapeable:

- **windows_exporter** (or **node_exporter** on non-Windows collectors) plus optional **textfile
  collector** directory: a scheduled job or small agent on each unit **atomically** writes
  `*.prom` snippets for custom facts (payload hash, module versions).
- A **small MAST-specific exporter** (single HTTP server) that gathers the same facts the unit
  probe would use (filesystem, services, optional WMI) and exposes **OpenMetrics** / Prometheus
  text format on `/metrics`.
- **Pushgateway** only where pull from the unit is impossible (firewall exception); default is
  **direct scrape** of the unit from Prometheus.

#### Installed package / manifest exposure

The **effective** installed state (what is really on disk and registered), not a stale copy that
could drift, must be representable for scraping, for example:

- **Gauge or info-style metrics:** `mast_payload_hash` as an info metric with labels for git SHA
  and payload hash (or separate labeled gauges if info metrics are not used).
- **Per-module signals:** `mast_module_present{module="..."} == 1`, optional
  `mast_module_version_info{module="...", version="..."} == 1` where versions are known.
- **Drift vs build:** If the prov server publishes the **current** `build-manifest` hash for
  that unit’s module set, the dashboard can compare **effective** vs **desired** in one place
  (either computed in the exporter or via recording rules in Prometheus).

Goal: the central dashboard shows a **table or stat panel per unit**: expected vs effective hash,
module checklist, and age of last successful alignment.

#### Running MAST services manifest

**Enumerate** MAST-related Windows services (fixed list per role or discovered from naming
conventions) and expose **running / stopped / missing** in a scrape-friendly form, for example:

- `mast_expected_service{service="..."} == 1` paired with `windows_service_state` from
  **windows_exporter**, or
- Custom `mast_service_up{service="..."}` (1 when Running and expected, 0 otherwise).

Include **start mode** where useful (Automatic vs Manual) so misconfiguration is visible.
Non-service processes required for science may use a separate **probe success** metric or a
dedicated heartbeat (see below).

#### Heartbeats and liveness

Heartbeats make **silent failure** visible on the dashboard without parsing logs:

- **Per-service or per-layer last OK time:** e.g. metrics such as
  `mast_heartbeat_timestamp_seconds{component="..."}` updated when smoke checks pass, or
  `time() - mast_last_success_timestamp_seconds` as a recording rule for **staleness**.
- **Provisioning loop:** On the prov server, expose **last successful autonomous run**,
  **per-unit last outcome** (`OK`, `SKIP`, `FAIL`, `UNREACHABLE`), and **last failure reason**
  as bounded labels or parallel info metrics so the command view shows **which unit needs attention**.
- **Scheduler / availability:** Integrate with **`availability.json`** (see **Unit Availability
  During Maintenance**) via metrics such as `mast_unit_available` and timestamps for last change,
  scraped from the unit or mirrored by an agent.

**Alerting:** Prometheus **Alertmanager** rules should fire when scrape fails (`up == 0`),
heartbeat age exceeds threshold, critical `mast_service_up == 0`, or effective payload hash
differs from desired for longer than a grace period after a known deploy.

#### Central command dashboard (Grafana or equivalent)

The **primary** operations UI should be a **dashboard** backed by the same Prometheus data:

- **Fleet row:** all units, green/yellow/red from heartbeats, availability, and last prov outcome.
- **Drill-down:** per-unit panels for **manifest** (hash, modules), **services grid**, **heartbeats**,
  **recent prov events** (linked or embedded from log-derived metrics if optional).
- **Prov server:** panels for scheduler health, LFS/git freshness if exposed, and aggregate failure rates.

Document **standard dashboard UIDs**, template variables (`hostname`, `site`), and which metrics
are **SLI**-grade (must not break during exporter upgrades without a migration note).

#### Relation to logs

Logs (`activity.csv`, remote-run transcripts, prov run logs) remain the **deep dive** for
incidents. Prometheus and the central dashboard provide **continuous, queryable, alertable**
summaries; they do not replace structured logging.

---

## Unit Availability During Maintenance (**target behavior**)

When a unit enters a maintenance window (provisioning, Windows Update, or reboot), it should be
marked unavailable to the MAST system so the scheduler does not assign observations to it.

### Mechanism (design intent)

`check-and-provision.ps1` (and related automation) would signal availability changes by writing a status file on the unit:

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

The MAST scheduler would read this file (via the same WinRM channel used for provisioning)
before assigning any observation job. A unit would only be eligible for scheduling when
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

### Log events (examples)

```
[2026-05-06T11:00:00Z] AVAIL_SET  unit=mast01 available=false reason=maintenance
[2026-05-06T11:07:10Z] AVAIL_SET  unit=mast01 available=true  reason=maintenance_complete
[2026-05-06T11:05:00Z] AVAIL_SET  unit=mast01 available=false reason=smoke_failure
```

---

## Windows Updates and Scheduled Reboots (**target operations**)

The flow below is the **intended** maintenance-window behavior once `check-and-provision.ps1`
implements scheduling integration and update orchestration. It is **not** a description of the
current script’s full surface area.

### Principle: daylight hours only

MAST units are observatory machines. Sky observations run at night. All disruptive maintenance
— Windows Updates, reboots, and any sysadmin tasks that take the unit offline — should be
confined to **daylight hours** (nominally 10:00–16:00 local site time), when no science data
can be collected regardless. The **target** provisioning scheduler would enforce this window.

**Planned:** `check-and-provision.ps1` would accept `-MaintenanceWindowStart` and
`-MaintenanceWindowEnd` parameters (24-hour local time, e.g. `10` and `16`). Runs that start
outside the window would skip update and reboot steps and log `MAINT_SKIP reason=outside_window`.

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
automatically. **Target:** installation would be triggered by `check-and-provision.ps1` during
the maintenance window so the provisioning server controls timing — not Windows Update's own scheduler.

```powershell
# Disable automatic install; allow download only (AUOptions = 3)
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' `
    -Name AUOptions -Value 3 -Type DWord
```

### Update + reboot sequence (inside maintenance window only)

**Target:** `check-and-provision.ps1` would run this sequence after all units have been provisioned:

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

**Target:** `check-and-provision.ps1` would depend on the
[PSWindowsUpdate](https://www.powershellgallery.com/packages/PSWindowsUpdate) module on each
unit, installed once during initial provisioning:

```powershell
Install-Module PSWindowsUpdate -Force -Scope AllUsers
```

Add this to `execute-mast-provisioning.ps1` or as a dedicated `windowsupdate` module in the
provisioning pipeline.

### Log events (examples)

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

### Summary (**target split**)

| Task | Runs when |
|------|-----------|
| MAST provisioning (software install) | Inside maintenance window |
| Windows Update check + install | Inside maintenance window |
| Reboot (if required) | Inside maintenance window, ≥30 min remaining |
| Smoke test re-run post-reboot | Immediately after reboot completes |
| All other `check-and-provision` logic (hash check, skip if current) | Any time |

The maintenance window parameters are stored in `unit-registry.json` per unit so sites at
different longitudes (and therefore different local sunrise/sunset times) can each have their
own window:

```json
{
  "hostname": "mast01",
  "timezone": "America/Los_Angeles",
  "maintenance_window": { "start_hour": 10, "end_hour": 16 },
  "modules": ["python", "ascom", "cygwin", "mast", "mongodb", "nomachine"]
}
```

---

## Unit Onboarding: One-Shot Bootstrap Script

The repo ships **`client/onboard-mast-unit.ps1`** with staged onboarding (preflight through
handoff). The subsections below describe the **intended end-to-end contract**; behavior may
still diverge on edge paths until the autonomous rollout items are closed.

### Target outcome

The design calls for a single script — `client/onboard-mast-unit.ps1` — to handle everything
from a bare Windows IoT install through to full autonomous operation. An operator runs it once
on the physical machine (or it is injected via answer file for VMs). **When that pipeline is
complete,** the unit should be:

- Named, networked, and WinRM-reachable
- Fully provisioned (all MAST software installed and smoke-tested)
- Registered with the provisioning server's unit registry
- Running the autonomous `check-and-provision` scheduled task

No further Mac or operator involvement would be needed for routine updates.

### Script stages (design)

```
onboard-mast-unit.ps1
  │
  ├── Stage 0  PREFLIGHT       Verify: admin rights, network reachability, vault creds accessible
  ├── Stage 1  BOOTSTRAP       Enable WinRM (HTTP), set hostname, create mast account
  ├── Stage 2  PREPARE         Harden WinRM (HTTPS), suppress Windows Update (DHCP; hostname is identity)
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
C:\MAST\logs\onboarding\onboarding.log
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
    Get-Content 'C:\MAST\logs\onboarding\mast01.log' -Wait
}
```

The prov server stores per-unit onboarding logs under:
```
C:\MAST\logs\onboarding\<hostname>.log
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
[11:02:14]  Stage 2 PREPARE            ✗ winrm_https_listener  →  Certificate or listener error
            To resume: .\onboard-mast-unit.ps1 -HostName mast01 -ResumeFrom 2
```

### Parameters

```powershell
.\onboard-mast-unit.ps1 `
    -HostName    mast01          `  # required (single source of truth for unit identity)
    -ProvServer  192.168.64.10   `  # IP or DNS name of provisioning server
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

### Handoff contract (**target steady state**)

After Stage 5 completes successfully, control **should** pass entirely to the provisioning server:

- `check-and-provision.ps1` runs on the prov server on a fixed cadence (for example every 30 minutes) via Task Scheduler or equivalent
- The unit's `availability.json` indicates `{available: true}`
- The unit’s **effective** provisioning state (preferably derived from live contents when probed,
  not only a cached file on the host or unit) reflects the provisioned payload hash
- Routine software updates or re-provisioning are triggered autonomously — no operator needed
- **SSH server** (OpenSSH Server on Windows) is **installed, configured, and running** for
  operator remote access per **Fleet SSH server (operator remote access)**

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
   .\onboard-mast-unit.ps1 -HostName mast01 -ProvServer 192.168.64.10
   ```
3. Walk away. Monitor from the Mac via the remote log tail shown above.
4. On success, the script exits with `ONBOARD_OK` — the unit should then match the handoff contract above.

---

## Rollout Steps

Work remaining to reach the **target** autonomous loop (partial progress may already exist in tree):

1. Add or complete `payload_hash` generation in `build-mast.ps1` → write `build-manifest.json`
   (include **git ref** fields when pinning by tag/commit is implemented)
2. Implement unit-side **effective** state: computed manifest and/or `installed-manifest.json`
   consistent with **Unit provisioning manifest (source of truth)** (inspection-based probe)
3. Per-module **uninstall/reinstall** (or equivalent) paths for clean upgrades; **build-mast** /
   driver support for **pinned git refs** and rollback deploys — see **Package lifecycle, MAST
   version pinning, rollback, and observability**
4. Extend `server/check-and-provision.ps1` (and related scripts) until they match the loop and
   observability described above — not a greenfield “write from scratch” unless the driver is
   replaced deliberately
5. Ensure `git lfs pull` works on the prov server (deploy key or stored credential)
6. Set up Task Scheduler trigger (or service wrapper) on the prov server
7. Run manual dry-runs (`check-and-provision.ps1 -DryRun`) to validate discovery + hash logic
8. Enable live runs; monitor logs / CSV for a week before treating as production
9. Stand up Prometheus scrape targets on units and the prov server (manifest, services,
   heartbeats); wire Grafana (or equivalent) **central command** dashboards and Alertmanager
   rules aligned with **Prometheus scrape targets and central command dashboard** above
10. Install and harden **OpenSSH Server** on fleet units; document firewall, auth, and smoke checks
    per **Fleet SSH server (operator remote access)**

---

## Open Questions

- **Git credential on prov server**: how are lfs credentials stored securely? (Windows
  Credential Manager, deploy key, PAT in vault?)
- **Network discovery vs hostname registry**: should units self-register (e.g., on boot send
  a UDP beacon), or is the hostname-only `unit-registry.json` sufficient for the expected unit count?
- **Rollback**: if provisioning fails on a unit, what is the recovery path? (Re-run from
  last known-good snapshot, or just retry next cycle?)
- **Concurrency**: provision units sequentially or in parallel? Parallel is faster but
  harder to debug; sequential is safer for a small fleet.

---

## Test-mode exceptions (blockers to declaring provisioning complete)

While we stabilize the end-to-end flow against a disposable VirtualBox VM, we currently rely
on a few **test-mode exceptions**. These must be eliminated (or made explicitly safe with
clear policy) before we can declare the autonomous provisioning system “complete” for
physical units.

### 1. No SMB share required (dev/test)

- **Current exception**: `build-mast.ps1` can run non-elevated with `-SkipSmbShare` (and
  `check-and-provision.ps1` passes it by default), so we can avoid UAC prompts and rely on
  WinRM `Copy-Item -ToSession` push.
- **Why it’s a blocker**: production may still need an alternate transfer mode (SMB pull,
  BITS/robocopy, etc.) for large fleets or when WinRM copy is slow/fragile.
- **Exit criteria**: choose and harden the production transfer mechanism; remove any
  reliance on “non-elevated build” as an implicit assumption.

### 2. Paid / sensitive artifacts skipped (licenses)

- **Current exception**: allow missing NoMachine license files during VM testing
  (e.g. `-AllowMissingNoMachineLicense`) so we don’t consume paid licenses on throwaway VMs.
- **Why it’s a blocker**: physical units require correct licensing and must fail loudly if
  licensing inputs are missing.
- **Exit criteria**: add an explicit license allocation policy for real units and require
  the license material for production runs (no “silent skip” outside test mode).

### 3. Optional GitHub token (mast module)

- **Current exception**: allow missing `vault/tokens/mast_github.txt` during test runs
  (`-AllowMissingGithubToken`) when the `mast` module is not being exercised.
- **Why it’s a blocker**: autonomous runs on a real provisioning server must have a clear,
  secure story for repo/LFS credentials (Credential Manager, deploy key, etc.).
- **Exit criteria**: decide how the provisioning server authenticates to Git/LFS and make
  that mandatory for production.

### 4. Large optional payloads (Astrometry)

- **Current exception**: `server/providers/cygwin/assets/astrometry.tgz` is treated as
  optional in dev/test runs; `provide-cygwin.ps1` skips astrometry expansion if the archive
  is missing.
- **Why it’s a blocker**: physical units that rely on astrometry must have the payload
  present and verified (hash, size, version), otherwise provisioning will be incomplete.
- **Exit criteria**: deliver the astrometry payload via an approved channel (Git LFS, local
  artifact cache, offline media), and make it required when the unit’s module set includes it.

### 5. Bootstrap security posture (HTTP + Basic)

- **Current exception**: early bootstrap uses WinRM over HTTP (5985) with `Basic` and
  `AllowUnencrypted=true` to simplify first-contact setup.
- **Why it’s a blocker**: production should converge to WinRM HTTPS (5986) with
  `AllowUnencrypted=false`, and a defined certificate/validation approach.
- **Exit criteria**: formalize the bootstrap → steady-state transition and ensure that
  the autonomous loop uses HTTPS by default, with HTTP allowed only for first-boot onboarding.
