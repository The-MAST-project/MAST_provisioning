# MAST Provisioning

Automated Windows provisioning for MAST telescope unit machines (`mast01`-`mast20`).

## Overview

The provisioning server (a long-lived Windows machine) builds a per-unit staging
payload from this repo, exposes it on an SMB share (`mast-staging`), and triggers
each unit to pull its own payload via `robocopy` over that share. The unit then runs
the provisioning script locally. Modules are self-describing via `module.json`
manifests; the orchestrator never has to know what software lives in which module.

In production this loop runs autonomously every N minutes via a Windows Task
Scheduler job (`server/check-and-provision.ps1`). In development we test the full
pipeline against a single VirtualBox VM on the same host.

```
+-----------------------------------+
| Windows host (the prov server)    |
|                                   |
|   Task Scheduler                  |
|     -> check-and-provision.ps1    |
|          -> build-mast.ps1        |
|          -> SMB pull by unit      |
|          -> execute on unit       |
|          -> verify smoke tests    |
|                                   |
|   VirtualBox (dev/test only)      |
|     +-------- mast-unit VM ------+|
|     |  DHCP / mast01 (DNS)       ||
|     |  WinRM, HTTPS              ||
|     +----------------------------+|
+-----------------------------------+
```

---

## Directory layout

```
MAST_provisioning/
|-- build/
|   `-- build-mast.ps1                # Assembles staging\<host>\01-provisioning\
|-- client/
|   |-- bootstrap-winrm.ps1           # First-time unit prep (single source of truth): mast user, site selection, auto-logon, WinRM HTTP, OpenSSH, Npcap, rename, WU policy, telemetry/privacy hardening, Windows Firewall OFF (units sit behind a perimeter firewall; WinRM/SSH rules kept for re-enable)
|   |-- execute-mast-provisioning.ps1 # Runs on the unit; iterates through commands.json
|   |-- run-verify-only.ps1           # Runs on the unit; *-verify steps only (see below)
|   `-- onboard-mast-unit.ps1         # Post-bootstrap onboarder: provision + register + handoff
|-- server/
|   |-- lib/mast-log.ps1              # Canonical log path definitions (unit + prov server)
|   |-- lib/provisioning.psm1         # Shared PS helpers
|   |-- providers/<module>/...        # Per-module install logic + assets
|   |-- check-and-provision.ps1       # Autonomous loop -- the production driver
|   |-- install-scheduled-task.ps1    # Wires check-and-provision.ps1 into Task Scheduler
|   |-- setup-smb-share.ps1           # One-time elevated setup: mast-staging share + mast-transfer account
|   `-- unit-registry.json.template   # Per-unit metadata, copy to unit-registry.json
|-- tools/
|   `-- run-remote-script-winrm.py    # Ad hoc remote PS1 runner via WinRM HTTP Basic
|-- vm/                               # VirtualBox and dev-host helpers (dev/test only)
|   |-- admin-prep.ps1                # One-time elevated host prep (PATH, ICMP firewall)
|   |-- build-autounattend-iso.ps1    # Builds autounattend ISO for unattended Windows install
|   |-- run-prov-test.py              # Dev-cycle test orchestrator (not the production driver)
|   |-- test-suite.py                 # Named scenarios on top of run-prov-test.py (run --list to see them)
|   |-- vm_lib.py                     # Canonical WinRM / creds / upload helpers; import from here, do not instantiate winrm.Session directly
|   |-- DEBUGGING.md                  # Convention for ad-hoc debug_*.py scripts using vm_lib
|   |-- sync-dev-unit-hosts.ps1       # Update Windows hosts file for VirtualBox DHCP guest
|   |-- vbox-create-unit.ps1          # Create the dev VirtualBox VM
|   |-- vbox-recreate-unit.ps1        # Full VM teardown and rebuild
|   `-- vm-fix-winrm.ps1              # Break-glass WinRM recovery (run locally on unit)
|-- vault/                            # Secrets, gitignored
|   |-- creds.json                    # WinRM credentials for units
|   |-- tokens/mast_github.txt        # GitHub PAT
|   `-- nomachine-licenses/*.lic
|-- staging/<host>/01-provisioning/   # Build output, gitignored
|-- DECISIONS.md
|-- autonomous-provisioning-requirements.md
`-- README.md
```

### Log locations

| Who writes | Where |
|------------|-------|
| Unit provisioning execution | `C:\MAST\logs\sessions\<timestamp>\` |
| Unit smoke markers | `C:\MAST\logs\smoke\` |
| Unit verify markers | `C:\MAST\logs\verify\` |
| Unit remote-run transcripts | `C:\MAST\logs\remote-runs\<timestamp>_<run_id>\` |
| Unit onboarding | `C:\MAST\logs\onboarding\` |
| Prov server autonomous loop | `C:\MAST\logs\prov\sessions\run-<timestamp>\` |
| Prov server activity history | `C:\MAST\logs\prov\activity.csv` |
| Dev test cycles (run-prov-test.py) | `C:\MAST\logs\dev\<timestamp>-cycle<N>\` |

All paths are defined in `server/lib/mast-log.ps1`; scripts import it rather than duplicating the base path.

### Verify-only (re-run checks without installers)

After you have a current `01-provisioning` folder on the unit (for example `C:\mast-staging` after a WinRM copy from `staging\<host>\01-provisioning\`):

```powershell
Set-Location C:\mast-staging
powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -File .\run-verify-only.ps1 -StagingPath .
```

This reads `commands.json`, runs only commands whose `module` name ends with `-verify`, and exits `1` if any step fails. Logs go under `C:\MAST\logs\sessions\<timestamp>\provisioning-verify-only.log`. It does not take the `execute.lock` used by full provisioning, so avoid running it at the same time as `execute-mast-provisioning.ps1`.

## Module execution order

The order below is the source of truth in each provider's `module.json` (`order`
field); this table is a generated snapshot of `server/providers/*/module.json` and
must be regenerated when modules are added, removed, or reordered rather than
hand-edited. Order numbers leave gaps so new modules can be inserted without
renumbering.

| Order | Module | Description |
|------:|--------|-------------|
|   100 | `proxy` | Soft proxy: set (on-campus) or clear (home) machine/WinHTTP/WinINet proxy settings |
|   150 | `config-bootstrap` | Lay down `C:\WIS\unit.toml` (machine identity + config-DB connection) and set `MAST_PROJECT=unit`; site chosen by build `-Site` |
|   200 | `openssh-server` | Drift check for OpenSSH Server (install/config owned by `bootstrap-winrm.ps1`) |
|   250 | `imdisk` | ImDisk driver; mount D: from the astrometry index image, persist across reboots |
|   300 | `cygwin` | Cygwin environment from a prebuilt tgz (postinstall, PATH) |
|   400 | `astrometry-dependencies` | Cygwin packages for astrometry.net + bundled `fitsio` wheel |
|   500 | `astrometry` | Prebuilt astrometry.net 0.97 tree into `C:\cygwin64\usr\local\astrometry` |
|   600 | `python` | Python 3.12.2 + virtualenv |
|   700 | `git` | Git for Windows (silent) + PATH |
|   750 | `gh` | GitHub CLI (gh) + PATH (after git) |
|   800 | `ascom` | ASCOM Platform 7.0 RC4 + Developer tools (enables .NET 3.5 if needed) |
|   900 | `mongodb-client` | MongoDB client tools: mongosh, Database Tools, Compass (no mongod) |
|  1000 | `npcap` | Verify Npcap driver (installed by bootstrap) + watchdog task |
|  1050 | `usbpcap` | USBPcap USB capture driver + tools |
|  1100 | `wireshark` | Wireshark 4.6.0 network analyzer |
|  1200 | `nssm` | NSSM (Non-Sucking Service Manager) + PATH |
|  1300 | `nomachine` | NoMachine Enterprise Desktop (server) + license |
|  1400 | `phd2` | PHD2 telescope autoguiding |
|  1450 | `phd2-log-viewer` | PHDLogView offline PHD2 guide-log analyzer |
|  1500 | `vcredist2013` | Visual C++ 2013 (MSVC120) x64 + x86 redistributables (for XILabs) |
|  1600 | `stage` | Optical stage / mount control software |
|  1700 | `planewave` | PlaneWave PWI4 + PWShutter + PS3 CLI + PlateSolve3 catalog + PWTools utility bundle |
|  1800 | `zwo` | ZWO camera drivers, ASI Studio, ASCOM driver |
|  1850 | `instrument-profiles` | Lay down PWI4 `.cfg` + PHD2 `.reg` **templates** (site location from `C:\WIS\unit.toml`; fleet constants verbatim) and apply into the `mast` profile on first logon. Per-unit device->COM binding is the post-hardware `tools/calibrate-instruments.ps1` step, not this provider. |
|  1900 | `vscode` | Visual Studio Code + bundled Python extensions (`ms-python.python`, `ms-python.debugpy`) installed offline from staged `.vsix` |
|  2000 | `sysinternals` | Sysinternals Suite |
|  2050 | `jupyter` | Jupyter Notebook + scientific stack (astropy, numpy, scipy, matplotlib, pandas, astroquery, photutils) in a contained venv under `C:\MAST\jupyter` (state kept there; launcher + desktop shortcut) |
|  2100 | `chrome` | Google Chrome (offline Enterprise MSI) |
|  2200 | `mast` | Clone MAST repos, create per-repo virtualenvs, install requirements |
|  2350 | `windows-update-lockdown` | Keep auto Windows Updates disabled: daily + at-startup SYSTEM task re-asserts the policy/services (Windows self-heals, so it must be re-applied) |
|  2400 | `windows-exporter-monitoring` | Prometheus windows_exporter service (TCP 9182) |
|  2500 | `diagnostics` | Post-smoke runtime checks (ASCOM, app launch, PHD2 RPC, heartbeat) |
|  2600 | `ds9` | SAOImage DS9 8.7 imaging / data visualization |
|  2700 | `desktop-shortcuts` | Operator shortcuts on the Public desktop (FastAPI control, weather page, DS9, MAST logs, **instrument calibration**, **Jupyter Notebook**) |
|  2900 | `mast-validation` | End-to-end plate-solve validation through production code paths |
|  9500 | `mast-services-finalize` | Set the MAST services (`mast-unit`, `mast-pwi4`, `mast-pwshutter`, `mast-phd2`) to **manual** start and stop them, as the last step after verification |
|  9999 | `reboot` | Detect pending-reboot state; drop a flag for the orchestrator |

The MAST NSSM services are named with a `mast-` prefix for findability (`mast-unit`,
`mast-pwi4`, `mast-pwshutter`, `mast-phd2`). They register auto-start and run **during**
provisioning so verification exercises them live; the `mast-services-finalize` provider then
flips them to **manual** start (and stops them) so a provisioned unit does not auto-start
telescope services on boot -- an operator raises them by hand in the wanted order. Manual
start is a deliberate current-development-stage measure and is expected to return to
automatic once the services are battle-tested (see DECISIONS 2026-07-01).

---

## Sites and per-site configuration

A **site** is a physical MAST location (`wis` = Weizmann dev/VM, `ns` = Neot Smadar
production). The operator picks the site explicitly at bootstrap -- it is **never**
derived from the hostname.

**Single source of truth for the site list:** the `*.toml` profiles under
`server/providers/config-bootstrap/sites/`. The file base name is the site code, and its
contents are that site's per-machine bootstrap config (site/project/controller_host/
domain/`[location]`). To add a site, drop `sites/<code>.toml` **and** add `<code>` to the
`$knownSites` list in `client/bootstrap-winrm.ps1` (see below).

**How the selection flows:** `bootstrap-winrm.ps1` (offline, on the bare unit) records the
chosen site to `C:\ProgramData\MAST\site.txt` -> `onboard-mast-unit.ps1` reads it and writes
it into the unit's `unit-registry.json` entry -> `check-and-provision.ps1` passes it to
`build-mast.ps1 -Site <code>`, which stages `sites/<code>.toml` for the `config-bootstrap`
provider to deploy as `C:\WIS\unit.toml`.

**Two site lists, kept in sync automatically:** `bootstrap-winrm.ps1` runs offline before
the prov server is reachable, so it cannot read `sites/` and embeds a `$knownSites` list for
console-time validation. `build-mast.ps1` runs `Assert-BootstrapKnownSitesInSync` on every
build (on the prov server, where both are visible) and **fails the build** if `$knownSites`
drifts from `sites/*.toml`. The shared enumerator is `Get-ConfiguredSites` in
`server/lib/mast-modules.psm1`.

**What is site-driven vs global:**

| Value | Source | Site-driven? |
|-------|--------|--------------|
| Machine identity + config-DB connection + `[location]` | `sites/<site>.toml` -> `C:\WIS\unit.toml` (`config-bootstrap`) | yes |
| RPi NTP time peer (tier 1) | `build-mast.ps1 -Site` injects `-RpiNtp` per site | yes |
| Instrument-profile PWI4 site location | read from deployed `C:\WIS\unit.toml [location]` | yes |
| Web proxy (Weizmann `bcproxy`) + `no_proxy` bypass | global default in the `proxy` provider | no -- both sites use the same Weizmann proxy; the per-run `weizmann`/`direct` axis is operator-chosen reachability, not site (see DECISIONS 2026-07-01) |

---

## Production path (physical unit)

This is the only path operators run by hand. Everything else is autonomous.

1. Install Windows IoT on the unit machine and complete OOBE.
2. Copy `client/bootstrap-winrm.cmd` and `client/bootstrap-winrm.ps1` to the unit
   via USB thumb drive or a temporary network share. Both files must be in the same
   folder. (In the VM workflow these files are bundled on the autounattend ISO; for
   physical units that ISO is not present, so manual copy is required.)
3. On the unit, open an **elevated Command Prompt** (Run as administrator) and run:

   ```cmd
   bootstrap-winrm.cmd
   ```

   The `.cmd` wrapper enables script execution for the session and invokes the `.ps1`.
   If you need to pass arguments (e.g. `-MastHostName mast05`), pass them directly:

   ```cmd
   bootstrap-winrm.cmd -MastHostName mast05
   ```

   Confirm the script prints `[OK]` before continuing.

4. Once bootstrap completes the unit is reachable over WinRM HTTP on port 5985. From
   here the provisioning server's Task Scheduler loop picks up the unit automatically
   and handles all further software installation and updates.

---

## Autonomous loop on the prov server

For complete step-by-step instructions starting from a bare Windows machine,
see **[docs/provisioning-server-setup.md](docs/provisioning-server-setup.md)**.

The abbreviated setup sequence is:

```powershell
# 1. Clone repo + pull LFS assets, populate vault/creds.json
# 2. Create server/unit-registry.json from the template

# 3. One-time elevated setup (SMB shares + mast-transfer account):
.\server\setup-smb-share.ps1

# 4. Install the Task Scheduler job (runs check-and-provision.ps1 every 30 min):
.\server\install-scheduled-task.ps1

# 5. Trigger the first run and watch logs:
Start-ScheduledTask -TaskName MAST-CheckAndProvision
Get-Content C:\MAST\logs\prov\sessions\run-*\*.log -Wait
```

Each run reads `server/unit-registry.json`, builds a per-unit staging payload,
compares the payload hash to the unit's installed manifest, and provisions any
unit whose hash has changed. Results are written to
`C:\MAST\logs\prov\activity.csv`.

---

## Fleet drift report (cross-unit version read)

`tools/fleet-drift-report.py` gives a quick, **read-only** cross-unit answer to "what
version is on each unit, and where do they differ?" -- useful as units are added and
drift creeps in. It gathers each unit's `C:\MAST\installed-manifest.json` over **SSH**
and prints a per-unit summary plus a module-version matrix flagging divergences (a
missing manifest shows as `NO-MANIFEST`). It changes nothing on the units.

```
# from the repo root on the prov server (or labcomp)
python tools/fleet-drift-report.py                       # all hosts in unit-registry.json
python tools/fleet-drift-report.py --hosts mast02,mast03
python tools/fleet-drift-report.py --build-manifest staging/mast03/01-provisioning/build-manifest.json
python tools/fleet-drift-report.py --json report.json --csv report.csv
python tools/fleet-drift-report.py --from-json report.json   # re-render a saved gather, no SSH
```

Exit code `0` = all units in sync, `2` = drift/missing/unreachable found, `1` = tool error.
This is the MVP of the "Version / Drift Detection" feature in
`autonomous-provisioning-requirements.md`; it trusts the static installed-manifest (the
computed/live manifest + tiered self-validation are the growth path).

---

## Dev/test loop (Windows host + VirtualBox VM)

This is the bring-up loop used while debugging modules. The Python orchestrator
`vm/run-prov-test.py` drives it. It is **dev-only**; the production driver is
`server/check-and-provision.ps1` running under Task Scheduler.

For the full one-time host setup (prerequisites, vault population, firewall,
DNS), see **[docs/provisioning-server-setup.md - Dev/test variant](docs/provisioning-server-setup.md#devtest-variant-virtualbox-on-the-same-host)**.

The quick summary: install Python 3.12 + pywinrm, run `vm\admin-prep.ps1`
(elevated once), and populate `vault\creds.json` from the template.

### One-time unit VM setup

Bootstrap (**`client\bootstrap-winrm.cmd`**) must run **elevated**: in File Explorer, right-click the `.cmd` file and choose **Run as administrator** (or run it from an **elevated Command Prompt** if you need arguments such as `-MastHostName`). The matching `bootstrap-winrm.ps1` must live in the same folder. Alternatively, run `bootstrap-winrm.ps1` from an elevated PowerShell session.

Two paths: an unattended path (recommended) and a manual path.

#### Unattended (no operator interaction during Windows install)

```powershell
# 1) Build a small autounattend ISO (~1 MB). It contains Autounattend.xml plus
#    bootstrap-winrm.cmd + bootstrap-winrm.ps1 on the ISO root (not executed automatically).
.\vm\build-autounattend-iso.ps1
# Optional: target ARM64 IoT LTSC and pick a specific edition
# .\vm\build-autounattend-iso.ps1 -Architecture arm64 -WindowsEdition "Windows 11 IoT Enterprise LTSC"

# 2) Create the VM with both ISOs mounted:
.\vm\vbox-create-unit.ps1 -IsoPath C:\path\to\Win11_or_IoTLTSC.iso `
                          -AutounattendIso .\autounattend-mast.iso

# 3) Start with GUI and wait ~15-25 min for Windows to finish:
VBoxManage startvm mast-unit --type gui

# 4) Log in (factory user/password1 by default). On the second DVD (or USB), locate
#    bootstrap-winrm.cmd in the same folder as bootstrap-winrm.ps1. Right-click
#    bootstrap-winrm.cmd and choose Run as administrator (required; the script
#    elevates WinRM and renames the computer). If you need command-line arguments,
#    open an elevated Command Prompt (Run as administrator) and run for example:
#        D:\bootstrap-winrm.cmd -MastHostName mast05 -RebootAfterBootstrap
#    The .cmd file runs PowerShell for you (.ps1 may open in Notepad if opened directly).
#    Confirm the script prints [OK] before you continue.

# 5) After reboot if prompted, log in as mast / physics. On the VirtualBox host (elevated):
.\vm\sync-dev-unit-hosts.ps1

# 6) Confirm reachability (use the same mastNN as in step 4):
Test-NetConnection mast05 -Port 5985

# 7) Power off, snapshot (bootstrap already did all prep -- there is no separate prepare step):
.\vm\vbox-create-unit.ps1 -SnapshotOnly
```

Defaults baked into the answer file for the first local account: `user` / `password1`
(until you run `bootstrap-winrm.cmd` as Administrator, or `bootstrap-winrm.ps1` from an elevated
PowerShell session, which sets `mast` / `physics`). Locale and
timezone default to `en-US` and `Israel Standard Time` unless overridden on
`build-autounattend-iso.ps1`.

#### Manual (walk through Windows setup yourself)

```powershell
# Create the VM (no Windows install yet):
.\vm\vbox-create-unit.ps1 -IsoPath C:\path\to\Win11_or_IoTLTSC.iso

# Start it and walk through Windows setup interactively:
VBoxManage startvm mast-unit --type gui

# Inside the VM after first login:
#   1) Ensure the host-only adapter has an address (DHCP on the VirtualBox
#      host-only network, or set a temporary address) and that mastNN resolves
#      from the host after you run bootstrap.
#   2) Run bootstrap: right-click client\bootstrap-winrm.cmd (or the copy on D:\ etc.)
#      and choose Run as administrator. For arguments (for example -MastHostName mast05),
#      use an elevated Command Prompt instead:
#         D:\bootstrap-winrm.cmd -MastHostName mast05
#      Bootstrap does all first-time prep (mast user, WinRM, OpenSSH, Npcap,
#      rename, WU policy, telemetry/privacy hardening, Windows Firewall OFF);
#      there is no separate prepare step.
#   3) Power off cleanly.

# Take the snapshots:
.\vm\vbox-create-unit.ps1 -SnapshotOnly
```

Either path produces two snapshots: `clean-state` (post-Windows install, before
manual bootstrap) and `post-prepare` (after `bootstrap-winrm.cmd` (Run as
administrator) ran -- bootstrap does all first-time prep; the snapshot name is
historical).

### Run a test cycle

```powershell
# Single cycle, all modules (--host-unit is the WinRM target: hostname preferred):
python .\vm\run-prov-test.py --host-unit mast01 --hostname mast01

# Just the build (no transfer / execute):
python .\vm\run-prov-test.py --host-unit mast01 --hostname mast01 --build-only

# Build, HTTP transfer to C:\mast-staging, then run *-verify steps only (no installers):
python .\vm\run-prov-test.py --host-unit mast01 --hostname mast01 --build-transfer-verify

# Three cycles, restoring the post-prepare snapshot between each:
python .\vm\run-prov-test.py --host-unit mast01 --hostname mast01 --repeat 3

# Subset of modules (faster iteration on a single problem):
python .\vm\run-prov-test.py --host-unit mast01 --hostname mast01 --modules python,mast
```

Cycle logs land in `C:\MAST\logs\dev\<timestamp>-cycle<N>\results.json`.

### Named scenarios (test-suite.py)

`vm/test-suite.py` wraps `run-prov-test.py` with named, repeatable scenarios
(full provision, mid-stream failure, recovery without snapshot reset,
per-module idempotency after manifest wipe, and STUBs for future work).

```powershell
# List all 11 scenarios (5 ACTIVE, 6 STUB):
python .\vm\test-suite.py --list

# Run one scenario:
python .\vm\test-suite.py --scenario full-provision --host-unit mast-wis-01

# Run every scenario (STUBs report SKIP):
python .\vm\test-suite.py --all --host-unit mast-wis-01
```

Suite results land in `C:\MAST\logs\dev\tests\<UTC-stamp>\suite-results.json`.

### Ad-hoc debugging against a unit

For one-off WinRM debugging (poke a service, push a patched source file,
check logs), follow the convention in `vm/DEBUGGING.md`: name the script
`debug_*.py`, import from `vm/vm_lib.py`, and never instantiate
`winrm.Session` directly.

---

## Smoke / verify

- `execute-mast-provisioning.ps1` exits 0
- `C:\Python312\python.exe --version` succeeds
- `C:\MAST\repos\` exists and has cloned repos with virtualenvs
- Every module wrote a non-empty `C:\MAST\logs\smoke\<module>-smoke.txt`
- `C:\MAST\installed-manifest.json` exists and matches the build's
  `payload_hash`

---

## Adding or modifying a module

1. Create `server/providers/<module>/module.json`:
   ```json
   {
     "name": "mymodule",
     "description": "...",
     "order": 150,
     "command": "powershell.exe -ExecutionPolicy Bypass -NonInteractive -File \".\\provide-mymodule.ps1\"",
     "commandfiles": ["provide-mymodule.ps1", "assets/installer.exe"],
     "verify": "powershell.exe ... smoke test ..."
   }
   ```
2. Drop scripts into `server/providers/<module>/`.
3. Drop binary assets into `server/providers/<module>/assets/`.
4. Add the module name to `unit-registry.json` `modules` lists (or it gets the default).

No edit to `execute-mast-provisioning.ps1` is required. `build-mast.ps1` copies `client/run-verify-only.ps1` into each staged `01-provisioning` folder for verify-only reruns.

---

## Secrets / vault

`vault/` is gitignored except for `vault/README.md` and `vault/creds.json.template`.
Never commit secrets, tokens, or `.lic` files.

---

## See also

- [docs/provisioning-server-setup.md](docs/provisioning-server-setup.md) - full installation guide (bare Windows -> running autonomous loop)
- [DECISIONS.md](DECISIONS.md) - architecture decisions, in reverse-chronological order
- [autonomous-provisioning-requirements.md](autonomous-provisioning-requirements.md) - design of the autonomous loop
- [unit-config-open-questions.md](unit-config-open-questions.md) - open questions on per-unit MongoDB `UnitConfig` fields
