# MAST Provisioning

Automated Windows provisioning for MAST telescope unit machines (`mast01`-`mast20`).

## Overview

The provisioning server (one long-lived machine) builds a per-unit staging
payload from this repo, exposes it on an SMB share (`mast-staging`), and triggers
each unit to pull its own payload via `robocopy` over that share. The unit then runs
the provisioning script locally. Modules are self-describing via `module.json`
manifests; the orchestrator never has to know what software lives in which module.

The driver is Python (`server/prov/`, entry point `server/check_and_provision.py`) and
runs on either OS; the steps it drives stay PowerShell and run on the units, which are
Windows throughout. In production it runs as a supervised service in `--loop` mode,
firing a cycle every N minutes (`server/deploy/`). In development we test the full
pipeline against a single VirtualBox VM on the same host.

```
+---------------------------------------+
| Prov server (Windows or Linux)        |
|                                       |
|   systemd unit / NSSM service         |
|     -> check_and_provision.py --loop  |
|          -> build-mast.ps1            |
|          -> SMB pull by unit          |
|          -> execute on unit (detached)|
|          -> verify smoke tests        |
|                                       |
|   VirtualBox (dev/test only)          |
|     +-------- mast-unit VM ----------+|
|     |  DHCP / mast01 (DNS)           ||
|     |  SSH (preferred), WinRM        ||
|     +--------------------------------+|
+---------------------------------------+
```

---

## Directory layout

```
MAST_provisioning/
|-- build/
|   `-- build-mast.ps1                # Assembles staging\<host>\01-provisioning\
|-- client/
|   |-- bootstrap.ps1           # First-time unit prep (single source of truth): hardware preflight (64 GB RAM + free D:), mast user, site selection, auto-logon, WinRM HTTP, OpenSSH, Npcap, rename, WU policy, telemetry/privacy hardening, Windows Firewall OFF (units sit behind a perimeter firewall; WinRM/SSH rules kept for re-enable)
|   |-- execute-mast-provisioning.ps1 # Runs on the unit; iterates through commands.json
|   |-- run-verify-only.ps1           # Runs on the unit; *-verify steps only (see below)
|   `-- onboard-mast-unit.ps1         # Post-bootstrap onboarder: provision + register + handoff
|-- server/
|   |-- lib/mast-log.ps1              # Canonical log path definitions (unit + prov server)
|   |-- lib/mast-firmware.ps1         # The only BIOS/UEFI reader: setup varstore + power-policy verdict
|   |-- lib/provisioning.psm1         # Shared PS helpers
|   |-- data/firmware-baseline.json   # Known-good BIOS setup per board + BIOS version (see Firmware baseline)
|   |-- providers/<module>/...        # Per-module install logic + assets
|   |-- prov/                         # The driver: orchestration, transport, drift, logging (Python)
|   |-- check_and_provision.py        # Entry point -- one cycle, or --loop for the autonomous cadence
|   |-- deploy/                       # Service wrappers: systemd unit + NSSM instructions
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
|   `-- nomachine-licenses/*.lic          # the ONLY home for NoMachine certificates
|-- staging/<host>/01-provisioning/   # Build output, gitignored
|-- docs/
|   |-- decisions/                    # Design rationale: one file per decision + the frozen archive
|   `-- *.md                          # Plans and analyses
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
|    20 | `mast-services-standdown` | **Remove** every MAST nssm service before anything else runs, so no part of the run can command telescope hardware and nothing is left that an accidental start could raise (a running `mast-unit` opens the mirror covers and homes the mount) |
|   100 | `proxy` | Soft proxy: set (on-campus) or clear (home) machine/WinHTTP/WinINet proxy settings |
|   150 | `config-bootstrap` | Lay down `C:\WIS\config.toml` (machine identity + config-DB connection) with the `machine_role` field injected; site chosen by build `-Site` |
|   200 | `openssh-server` | Drift check for OpenSSH Server (install/config owned by `bootstrap.ps1`) |
|   250 | `imdisk` | ImDisk driver; assert the machine has the fleet's required RAM, then mount D: from the astrometry index image, persist across reboots |
|   300 | `cygwin` | Cygwin environment from a prebuilt tgz (postinstall, PATH) |
|   400 | `astrometry-dependencies` | Cygwin packages for astrometry.net (offline, from the frozen build-host cache `C:\MAST\cygwin-pkg-cache`) + bundled `fitsio` wheel |
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
|  1300 | `nomachine` | NoMachine Enterprise Desktop (server) + license. Pins `SessionHistory 0` (the 9.0.188 history cleaner crashes the server, see `docs/decisions/2026-08-03-nomachine-pins-server-cfg-and-verifies-serving.md`) and `UpdateFrequency 0`, then leaves `nxd` accepting NX connections on 4000 — re-running repairs a unit a past crash loop had disabled |
|  1400 | `phd2` | PHD2 telescope autoguiding |
|  1450 | `phd2-log-viewer` | PHDLogView offline PHD2 guide-log analyzer |
|  1500 | `vcredist2013` | Visual C++ 2013 (MSVC120) x64 + x86 redistributables (for XILabs) |
|  1600 | `stage` | Optical stage / mount control software |
|  1700 | `planewave` | PlaneWave PWI4 + PWShutter + PS3 CLI + PlateSolve3 catalog + PWTools utility bundle. Pre-trusts the PlaneWave and TI Tiva/Stellaris driver publishers and stages PWI4's bundled USB drivers with `pnputil`, outside the installer's idempotency guard so a re-run repairs an already-installed unit |
|  1800 | `zwo` | ZWO camera drivers, ASI Studio, ASCOM driver |
|  1850 | `instrument-profiles` | Lay down PWI4 `.cfg` + PHD2 `.reg` **templates** (site location from `C:\WIS\config.toml`; fleet constants verbatim) and apply into the `mast` profile on first logon. Per-unit device->COM binding is the post-hardware `tools/calibrate-instruments.ps1` step, not this provider. |
|  1900 | `vscode` | Visual Studio Code + bundled Python extensions (`ms-python.python`, `ms-python.debugpy`) installed offline from staged `.vsix` |
|  2000 | `sysinternals` | Sysinternals Suite |
|  2050 | `jupyter` | Jupyter Notebook + scientific stack (astropy, numpy, scipy, matplotlib, pandas, astroquery, photutils) in a contained venv under `C:\MAST\jupyter` (state kept there; launcher + desktop shortcut) |
|  2100 | `chrome` | Google Chrome (offline Enterprise MSI) |
|  2200 | `mast` | Clone MAST repos, create the venv, install requirements, open the unit API port. Registers no service |
|  2210 | `mast-shared-mount` | Map `Z:` to the operational share `\\<controller_host>\mast-share` **in the LocalSystem session** (SYSTEM at-startup task); clear stale per-user mappings |
|  2350 | `windows-update-lockdown` | Keep auto Windows Updates disabled: daily + at-startup SYSTEM task re-asserts the policy/services (Windows self-heals, so it must be re-applied) |
|  2400 | `windows-exporter-monitoring` | Prometheus windows_exporter service (TCP 9182) |
|  2500 | `diagnostics` | Post-smoke runtime checks (ASCOM, app launch, PHD2 RPC). Nothing here touches the MAST services |
|  2600 | `ds9` | SAOImage DS9 8.7 imaging / data visualization |
|  2700 | `desktop-shortcuts` | Operator shortcuts on the Public desktop (FastAPI control, weather page, DS9, MAST logs, **instrument calibration**, **Jupyter Notebook**) |
|  2750 | `desktop-appearance` | Every per-user desktop value: dark Windows theme, a dark background carrying the machine's identity (hostname, site spelled out, site coordinates), and the toast / content-delivery quieting that used to sit in bootstrap. Written into the autologin `mast` hive and re-asserted in that session by an AtLogon task |
|  2900 | `mast-validation` | End-to-end plate-solve validation through production code paths. **On-site only**: the solver reads its acquisition ROI from the config DB, so a unit that cannot reach its controller fails here |
|  9500 | `mast-services-finalize` | Assert the end-of-run posture: no MAST service is registered |
|  9999 | `reboot` | Detect pending-reboot state; drop a flag for the orchestrator |

**Provisioning registers no Windows service, and removes any it finds.** The four MAST nssm
services (`mast-unit`, `mast-pwi4`, `mast-pwshutter`, `mast-phd2`) are deleted at order 20 and
again by the driver before the build and transfer; `tools/mast-service-names.ps1` holds the
names, and `mast-services-finalize` asserts at 9500 that none came back.

None of the four has a job. The unit is run by hand and raises PWI4, ps3cli and PHD2 itself,
and PWShutter lost its consumer when the covers moved to PWI4's `mirrorcover` API
(`MAST_unit#134`). So a registered service is a *competing* path rather than a redundant one:
`ensure_process_is_running` adopts by name, so a session-0 PWI4 raised by `mast-pwi4` is
adopted by a hand-run unit and the operator gets one that can neither draw nor see `Z:`. On
top of that a running `mast-unit` commands hardware on process start -- the mirror covers open
and the mount homes (`MAST_unit#132`) -- with no interlock anywhere in the stack.

The pre-rename names (`PWI4`, `PWShutter`, `PHD2`) are removed too, but only when nssm-hosted,
which is what proves the registration is ours rather than a service of the same name installed
by something else. Provisioning delivers the environment and does not test the unit. See
`docs/decisions/2026-08-30-provisioning-registers-no-mast-service.md` and issue #159.

---

## Sites and per-site configuration

A **site** is a physical MAST location (`wis` = Weizmann dev/VM, `ns` = Neot Smadar
production). The operator picks the site explicitly at bootstrap -- it is **never**
derived from the hostname.

**Single source of truth for the site list:** the `*.toml` profiles under
`server/providers/config-bootstrap/sites/`. The file base name is the site code, and its
contents are that site's per-machine bootstrap config (site/project/controller_host/
domain/`[location]`). To add a site, drop `sites/<code>.toml` **and** add `<code>` to the
`$knownSites` list in `client/bootstrap.ps1` (see below).

**How the selection flows:** `bootstrap.ps1` (offline, on the bare unit) records the
chosen site to `C:\ProgramData\MAST\site.txt` -> `onboard-mast-unit.ps1` reads it and writes
it into the unit's `unit-registry.json` entry -> the driver passes it to
`build-mast.ps1 -Site <code>`, which stages `sites/<code>.toml` for the `config-bootstrap`
provider to deploy as `C:\WIS\config.toml`.

**Two site lists, kept in sync automatically:** `bootstrap.ps1` runs offline before
the prov server is reachable, so it cannot read `sites/` and embeds a `$knownSites` list for
console-time validation. `build-mast.ps1` runs `Assert-BootstrapKnownSitesInSync` on every
build (on the prov server, where both are visible) and **fails the build** if `$knownSites`
drifts from `sites/*.toml`. The shared enumerator is `Get-ConfiguredSites` in
`server/lib/mast-modules.psm1`.

**What is site-driven vs global:**

| Value | Source | Site-driven? |
|-------|--------|--------------|
| Machine identity + config-DB connection + `[location]` | `sites/<site>.toml` -> `C:\WIS\config.toml` (`config-bootstrap`) | yes |
| RPi NTP time peer (tier 1) | `build-mast.ps1 -Site` injects `-RpiNtp` per site | yes |
| Instrument-profile PWI4 site location | read from deployed `C:\WIS\config.toml [location]` | yes |
| Web proxy (Weizmann `bcproxy`) + `no_proxy` bypass | global default in the `proxy` provider | no -- both sites use the same Weizmann proxy; the per-run `weizmann`/`direct` axis is operator-chosen reachability, not site (see DECISIONS 2026-07-01) |

---

## Production path (physical unit)

This is the only path operators run by hand. Everything else is autonomous.

1. Install Windows IoT on the unit machine and complete OOBE.
2. Copy `client/bootstrap.cmd`, `client/bootstrap.ps1` and
   `client/mast-client-util.ps1` to the unit via USB thumb drive or a temporary network
   share. All three files must be in the same folder. (In the VM workflow these files are
   bundled on the autounattend ISO; for physical units that ISO is not present, so manual
   copy is required.)
3. On the unit, open an **elevated Command Prompt** (Run as administrator) and run:

   ```cmd
   bootstrap.cmd
   ```

   The `.cmd` wrapper enables script execution for the session and invokes the `.ps1`.
   If you need to pass arguments (e.g. `-MastHostName mast05`), pass them directly:

   ```cmd
   bootstrap.cmd -MastHostName mast05
   ```

   Confirm the script prints `[OK]` before continuing.

   The first thing it does is assert the unit's hardware: **64 GB of RAM** and a **free
   drive letter D:**, both required by the `imdisk` provider's 32 GB RAM-backed D: mount.
   A machine missing either stops here, before anything has been changed on it -- fit the
   memory (or pull the disk holding D:) and re-run. On a bare unit the bootstrap USB
   itself takes D: (`C:` is the system disk); that is recognized and is **not** a failure,
   and the run ends by telling you to unplug it. The memory requirement is declared once,
   in `Get-MastRequiredMemoryGB` (`server/lib/mast-modules.psm1`); `bootstrap.ps1`
   embeds it because it runs offline, and `build-mast.ps1` fails the build if the two
   drift.

4. **Unplug the bootstrap drive** when the run tells you to, before any reboot. A drive
   left physically plugged in is picked up again on the next boot and takes `D:` back --
   which is the state the preflight exists to prevent. Nothing automates this: bootstrap
   used to eject the volume, which killed the `cmd` wrapper reading its own batch file
   off it (#107), and the eject never survived a reboot anyway.

5. Once bootstrap completes the unit is reachable over WinRM HTTP on port 5985. From
   here the provisioning server's Task Scheduler loop picks up the unit automatically
   and handles all further software installation and updates.

---

## Autonomous loop on the prov server

> **The driver is Python.** The server orchestration is
> `server/check_and_provision.py` + the `server/prov/` package, so the prov server can run
> on any OS while units stay Windows. Run one cycle with
> `python server/check_and_provision.py [--only-hosts ...] [--dry-run]`
> (`pip install -r server/requirements.txt` first); tests and lint are described under
> **[Tests and CI](#tests-and-ci)** below. The **supervised loop** is `--loop`
> (`--interval-seconds`, `--max-cycles`); run it as a service per
> **[server/deploy/README.md](server/deploy/README.md)** (systemd unit / NSSM). See
> `docs/decisions/2026-07-12-loop-mode-is-a-long-lived-service.md`.
>
> The PowerShell driver `server/check-and-provision.ps1` and its Task Scheduler installer
> were **retired on 2026-08-16**
> (`docs/decisions/2026-08-16-the-powershell-driver-is-retired.md`), once the Python driver
> had been provisioning the production units for a week. What has *not* yet run in
> production is the **unattended cadence** -- every fleet run so far has been a one-shot
> invocation, and `--loop` under a supervisor is still VM-only evidence.

For complete step-by-step instructions starting from a bare Windows machine,
see **[docs/provisioning-server-setup.md](docs/provisioning-server-setup.md)**.

## Pinning the upstream repos

`tools/mast-repos.tsv` is the single source of truth for which upstream repos a
machine clones, and for which revision. It is read by both `tools/mast-clone.ps1`
and `tools/mast-clone.sh`, which must not diverge.

```
# dir	repo	roles	branch	rev
common	MAST_common	unit,control,spec	master	v1.4.0
unit	MAST_unit.2024-12-12	unit	main
```

(Nothing is pinned as shipped — every row's `rev` is empty. The `v1.4.0` above is
illustrative.)

The 5th `rev` column is **optional**:

- **Empty (or absent)** — track the branch. `-Update` fast-forwards. This is the
  historical behaviour, and it means a machine gets whatever the branch head was
  at the moment *its* clone ran.
- **Set** — a tag (preferred) or commit SHA. The repo is checked out **detached**
  at that revision and does **not** move on `-Update`; it moves only when this
  column moves.

A `-Branch`/`--branch <dir>=<ref>` override **disables** that folder's pin, logged
loudly, so a developer can follow a feature branch without editing the manifest.

`tools/fleet-drift-report.py` reports these across the fleet under
**Upstream repos**, flagging `*` for a unit that resolved to a different commit and
`!` for one where a pin was requested but the checkout is on a branch. Absence is
split by whether the unit's **role** pulls that repo, read from the `roles` column of
the same manifest: `MISSING` (expected and not there — a real gap, counted as drift)
versus `n/a` (control-only `gui` on a unit, say — benign). `--role` overrides the
default of `unit`.

Every run writes `<Top>/clone-manifest.json` recording, per repo, the branch, the
`rev` as *requested*, and the `resolved_sha` that actually landed —
`Merge-MastInstalledManifest` folds it into the unit's `installed-manifest.json` as
`repos`, so a unit can be asked what it is running. The requested/resolved pair is
what makes a force-moved tag visible.

Why this exists: sibling clones replaced git submodules, which pinned a commit by
construction. Without a `rev` the fleet can silently diverge — on 2026-08-11 two
upstream merges landed mid-fleet-run and left three units on two different
`MAST_common` commits, every run reporting success. See
`docs/decisions/2026-08-11-mast-clone-pins-a-revision-and-records-what-landed.md`.

## Tests and CI

```bash
pip install -r server/requirements.txt -r requirements-dev.txt   # both, see below
python -m pytest -q -ra                                          # from the REPO ROOT
ruff format --check . && ruff check .
basedpyright                                                     # type check
```

```powershell
Import-Module Pester -RequiredVersion 3.4.0 -Force                # NOT a bare Import-Module
Invoke-Pester -Path server\tests
.\tools\invoke-psscriptanalyzer.ps1                               # PowerShell lint
```

Four things are easy to get wrong, and CI (`.github/workflows/ci.yml`) encodes all four:

- **Install the runtime deps too, not just `requirements-dev.txt`.** `prov.transport`
  imports `pywinrm` and `vm/run-prov-test.py` imports `paramiko` at module level, so
  without them pytest dies during *collection* with `INTERNALERROR` and reports zero
  tests rather than failing one.
- **Run pytest from the repo root.** `server/prov/tests` alone skips `vm/tests`.
- **Pin Pester to 3.4.0.** The suites are Pester 3 syntax (`Should Be`, not
  `Should -Be`); Windows ships 5.x alongside 3.4.0 and a bare `Import-Module Pester`
  picks 5.x, where every assertion is a syntax error. Windows PowerShell 5.1, not `pwsh`.
- **The type check needs the runtime deps too, for a different reason than pytest.**
  Pyright resolves imports from the environment, so without `pywinrm`/`paramiko` it
  reports `reportMissingImports` across the whole transport layer and proves nothing about
  the code. (`ruff` never imports anything, which is why the `lint` job installs less.)

Lint uses the fleet-wide `ruff.toml` (shared with MAST_common and MAST_unit) with
`ruff` pinned in `requirements-dev.txt` — the pin matters for the default rule set, not
only formatter output. CI also parse-checks every `.ps1`/`.psm1`; see
`docs/decisions/2026-08-11-ci-is-three-jobs-and-lands-green.md`.

PowerShell is linted by **PSScriptAnalyzer**, pinned to 1.25.0 by
`tools/install-psscriptanalyzer.ps1` (which owns both install paths -- `Install-Module`
on CI, a direct `.nupkg` fetch where PowerShellGet's NuGet bootstrap fails behind a
proxy). Rules live in `PSScriptAnalyzerSettings.psd1`; run it with
`tools/invoke-psscriptanalyzer.ps1`, the same entry point CI uses. Blocking and green.

Accepted findings are declared **at the site** with
`[Diagnostics.CodeAnalysis.SuppressMessageAttribute]` and a justification, because
PSScriptAnalyzer has no per-line suppression comment; where a finding has no function
or param block to attach one to, it carries a `# pssa-ignore: <Rule> -- <reason>`
comment on (or directly above) the flagged line, which the runner reads -- the
`# noqa` PowerShell does not have. A reason is required, and a stale annotation is
itself an error. Why these
rules and not others, and which two were excluded for finding nothing real:
`docs/decisions/2026-08-18-powershell-is-linted-by-psscriptanalyzer.md`.

Types are checked by `basedpyright` (pyright plus a stricter default rule set), pinned in
`requirements-dev.txt` and configured by `pyrightconfig.json` at the repo root:
`typeCheckingMode: "standard"` set explicitly, and `pythonPlatform: "All"` so one Linux
run covers the Windows branches as well. Blocking, and green. Pylance in VS Code reads the
same config file, so the editor and CI agree on what counts. Why pyright and not mypy, and
what the first 50 findings turned out to be:
`docs/decisions/2026-08-17-pyright-not-mypy-for-the-python-server.md`.

The abbreviated setup sequence is:

```powershell
# 1. Clone repo + pull LFS assets, populate vault/creds.json
# 2. Create server/unit-registry.json from the template

# 3. One-time elevated setup (SMB shares + mast-transfer account):
.\server\setup-smb-share.ps1

# 4. Install the driver's dependencies:
pip install -r server\requirements.txt

# 5. Trigger the first run by hand and watch logs:
python server\check_and_provision.py --dry-run
Get-Content C:\MAST\logs\prov\sessions\run-*\*.log -Wait

# 6. Install the service wrapper for the autonomous cadence -- see server\deploy\README.md
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
missing manifest shows as `NO-MANIFEST`). It also reads each unit's
`C:\MAST\bootstrap-manifest.json` (stamped by `bootstrap.ps1`) and flags units on
an older or unstamped bootstrap, listing the bootstrap elements they may be missing
(element history in `client/bootstrap-elements.json`). It changes nothing on the units.

### The bootstrap element registry

`client/bootstrap-elements.json` records what a bootstrap of version N establishes:
one entry per element, with the `since:` version that introduced it. It is what
lets the report above name what a unit is missing.

Each element also declares **`reassert:`** — whether it may be run again on an
**already-provisioned** unit. That is the question a remote re-bootstrap has to
answer per element (see #143), because some of them would cut the channel the run
travels over:

| `reassert` | Meaning |
|---|---|
| `routine` | Safe to re-assert on every provisioning run |
| `provider` | A provisioning provider already re-asserts it — named in `provider:`. Do **not** run bootstrap's copy again |
| `on-demand` | Can run remotely, but never on a routine run. Invoked explicitly, for repair |
| `console` | First touch only. Never remote |

`winrm-http-basic` and `openssh-from-msi` are `on-demand` deliberately: reinstalling
the transport under a live session is how a healthy unit becomes an unreachable one
(#123 — mast06 finished a "clean" bootstrap with no SSH server). Repair is still
remote, because **each transport is the other's rescue path** — fix sshd over WinRM,
fix the WinRM listener over SSH.

The `routine` and `on-demand` elements are **dispatchable**: each is a function in
`bootstrap.ps1`, mapped by id in `$script:MastBootstrapElementActions` and called by the
main flow through `Invoke-MastBootstrapElement -Id <id>`. `console` and `provider`
elements deliberately are **not** — reaching a first-touch element remotely is the
failure the classification exists to prevent.

### Re-asserting an already-provisioned unit

```powershell
.\bootstrap.ps1 -ReassertOnly                              # every 'routine' element
.\bootstrap.ps1 -ReassertOnly -Elements locale-en-us,service-trim
.\bootstrap.ps1 -ReassertOnly -Elements openssh-from-msi   # repair, named explicitly
```

No prompts, no reboot, and none of bootstrap's first-touch work — no hardware preflight,
account, autologon, rename, Npcap or media handling. The default set is every `routine`
element; an `on-demand` element runs **only** when named, which is what keeps the two
transport elements out of a routine convergence pass. Naming a `console` or `provider`
element, or an unknown id, **refuses the whole run** (exit 1, nothing applied) rather
than skipping it quietly — a silent skip would let you believe an element you explicitly
asked for had been applied.

It records a `reassert` block in `C:\MAST\bootstrap-manifest.json` and **deliberately
does not touch `bootstrap_version`**: a re-assert applies the routine elements and by
construction not the console ones, so the unit is not at the current bootstrap version
afterwards, and the drift report must go on saying so.

**This runs by itself.** The `bootstrap-reassert` provider (`always: true`, order 15 —
after `execution-policy`, ahead of everything that installs) invokes it on **every**
provisioning cycle, so a unit converges without anyone visiting it. That is also why an
element which assumes an interactive session must be classified `console`: a provisioning
run is Session 0. `locale-en-us` is the worked example — its `Set-WinHomeLocation`
activates a `RunAs = Interactive User` COM server that stalls 600 s in Session 0 and then
succeeds anyway (#148), so it is console-only. It runs
unconditionally rather than only when a unit looks behind: a unit whose
`bootstrap_version` is `null` because it predates stamping is not "behind" by that test,
and that unit is exactly the one most in need of converging. `bootstrap.ps1` and
`mast-client-util.ps1` reach the unit as the provider's `repofiles`. A failed element
fails the module — unlike the BIOS check, this is work provisioning owns and can retry.

`build-mast.ps1` fails the build if the registry is malformed, if an element omits or
mis-spells `reassert`, if a `provider`-backed element names a provider that does not
exist, if `current_version` disagrees with either the newest `since:` or
`$script:BootstrapVersion`, **or if the registry and the dispatch map disagree** — a
re-assertable element the script cannot dispatch, a dispatched id that is not a
re-assertable element, or a map entry naming a function that does not exist.

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

### Runbook: the report says a unit is behind -- now what?

The bootstrap section answers this directly. It splits what a unit is missing by **who
can fix it**, so the only question left is whether you need to go anywhere:

```
  mast02: v2 OUTDATED (current 13)
      self-heals next cycle : service-trim, timezone-israel-dst
      NEEDS A CONSOLE VISIT : npcap
      on-demand             : openssh-from-msi
      provider              : execution-policy
      re-asserted 2026-08-25T06:59:44Z (7 routine element(s) applied)
```

Read it line by line:

- **`self-heals next cycle`** — nothing to do. The `bootstrap-reassert` provider applies
  these on the unit's next provisioning cycle. If you want them now, trigger a cycle.
- **`NEEDS A CONSOLE VISIT`** — the only line that costs you a trip. These are `console`
  elements: first-touch work (the account, autologon, rename), or work that needs an
  interactive session. Nothing remote will ever apply them.
- **`on-demand`** — capable of running remotely, but never on a routine run, because
  both entries re-assert the transport the run travels over. To repair one, name it, on
  one unit, over the *other* channel:
  ```powershell
  .\bootstrap.ps1 -ReassertOnly -Elements openssh-from-msi   # fix sshd over WinRM
  .\bootstrap.ps1 -ReassertOnly -Elements winrm-http-basic   # fix WinRM over SSH
  ```
- **`provider`** — nothing to do here either; a provisioning provider owns it (named in
  `bootstrap-elements.json`), and it is re-asserted on its own schedule.
- **`re-asserted <when>`** — an annotation, not an all-clear. It says the routine
  elements were applied then. The unit stays flagged because `bootstrap_version` does
  not advance on a re-assert, and the console line above is still outstanding.

`UNSTAMPED` means the unit predates bootstrap version stamping, so **nothing** is known
about which elements it has -- every element is listed as unverified. That is not the
same as being broken; it is the same work order, with no evidence to narrow it.

The `RESULT` block at the end names only the units that actually need a person, or says
plainly that every gap self-heals on the next cycle.

---

## Firmware baseline (BIOS power policy)

A unit must power itself back on when mains returns -- the DLI switch cuts and restores
AC, and a unit set to stay off is absent from the fleet until somebody drives to the
site. That setting is `Advanced -> APM Configuration -> Restore AC Power Loss = S0 State`
in BIOS setup. **Provisioning can read it and cannot write it**, so this is always a
manual fix; what the code does is make sure nobody finds out the hard way.

`server/lib/mast-firmware.ps1` is the only reader. It takes the AMI setup varstore
(the UEFI variable `Setup`, read with `SeSystemEnvironmentPrivilege`) and compares it
against `server/data/firmware-baseline.json`, which records, per **baseboard product +
BIOS version**, the known-good whole-blob hash and the byte offsets of the fields we
have named. Two callers use it, both non-blocking:

- **`client/bootstrap.ps1`**, at the console. A needs-attention result prints a red
  banner and waits up to 120 s for the operator to press `y`, then continues on its own.
  `-NonInteractive` never prompts. The result and whether a human acknowledged it are
  stamped into `C:\MAST\bootstrap-manifest.json`.
- **`verify-power-management.ps1`**, during a provisioning run. It logs `[WARN]` lines
  and writes module facts; it never fails the module. The facts reach
  `installed-manifest.json`, so `tools/fleet-drift-report.py` shows a **BIOS power
  policy** section across the fleet.

Statuses: `match`; `field-drift` (a named power field is wrong -- attention);
`unknown-baseline` (no entry for this board and BIOS, or a varstore whose length the
baseline does not describe -- attention, because unverified is not the same as good);
`blob-drift` (the hash moved but every named field is right -- reported, no prompt);
`unavailable` (no such variable: the dev VM, a legacy-BIOS box).

### Re-baselining, and adding a board

**A BIOS update or a new board model invalidates both the hash and every offset**, and
new hardware reports `unknown-baseline` until it is added. Offsets are *measured*, never
derived -- the ASUS setup-item catalog preserves order but not spacing, so counting it
gives wrong answers. To add a board:

1. At the console, confirm `Restore AC Power Loss` reads `S0 State` (and the APM wake
   sources read `Disabled`). The baseline must be verified by eye, not assumed.
2. On the unit, dump the varstore:
   `. mast-firmware.ps1; $s = Get-MastFirmwareSetup; $s.Sha256; $s.Length; [Convert]::ToBase64String($s.Bytes)`
3. To locate a field: dump, toggle **that one setting** in BIOS setup, save, reboot, dump
   again, and diff. Exactly one byte moves; that is the offset, and the value in the
   known-good dump is `expect`. Change one setting per pass or the diff is ambiguous.
4. Add a `boards[]` entry with `baseboard_product`, `bios_version`, `setup_length`,
   `setup_sha256`, `setup_base64`, `captured_from`, `captured_at`, `verified_by` and the
   `fields`. `server/tests/mast-firmware.Tests.ps1` checks the entry is internally
   consistent.
5. **Re-cut the USB/ISO kit.** The reader and the baseline are staged onto the bootstrap
   medium, so a kit cut before the change carries the old baseline and will report
   `unknown-baseline` on hardware that is actually fine.

Known offsets for `PE2100U-C7136ES` BIOS `1.03.00` (measured on mast08, 2026-08-24):
`Restore AC Power Loss` = 3378 (expect 1), `Power On By PCIE/PCI` = 3380 (expect 0),
`Power On By Ring` = 3381 (expect 0).

---

## Dev/test loop (Windows host + VirtualBox VM)

This is the bring-up loop used while debugging modules. The Python orchestrator
`vm/run-prov-test.py` drives it. It is **dev-only**; the production driver is
`server/check_and_provision.py` running as a supervised `--loop` service.

For the full one-time host setup (prerequisites, vault population, firewall,
DNS), see **[docs/provisioning-server-setup.md - Dev/test variant](docs/provisioning-server-setup.md#devtest-variant-virtualbox-on-the-same-host)**.

The quick summary: install Python 3.12 + pywinrm, run `vm\admin-prep.ps1`
(elevated once), and populate `vault\creds.json` from the template.

### One-time unit VM setup

Bootstrap (**`client\bootstrap.cmd`**) must run **elevated**: in File Explorer, right-click the `.cmd` file and choose **Run as administrator** (or run it from an **elevated Command Prompt** if you need arguments such as `-MastHostName`). The matching `bootstrap.ps1` must live in the same folder. Alternatively, run `bootstrap.ps1` from an elevated PowerShell session.

Two paths: an unattended path (recommended) and a manual path.

#### Unattended (no operator interaction during Windows install)

```powershell
# 1) Build a small autounattend ISO (~1 MB). It contains Autounattend.xml plus
#    bootstrap.cmd + bootstrap.ps1 on the ISO root (not executed automatically).
.\vm\build-autounattend-iso.ps1
# Optional: target ARM64 IoT LTSC and pick a specific edition
# .\vm\build-autounattend-iso.ps1 -Architecture arm64 -WindowsEdition "Windows 11 IoT Enterprise LTSC"

# 2) Create the VM with both ISOs mounted:
.\vm\vbox-create-unit.ps1 -IsoPath C:\path\to\Win11_or_IoTLTSC.iso `
                          -AutounattendIso .\autounattend-mast.iso

# 3) Start with GUI and wait ~15-25 min for Windows to finish:
VBoxManage startvm mast-unit --type gui

# 4) Log in (factory user/password1 by default). On the second DVD (or USB), locate
#    bootstrap.cmd in the same folder as bootstrap.ps1. Right-click
#    bootstrap.cmd and choose Run as administrator (required; the script
#    elevates WinRM and renames the computer). If you need command-line arguments,
#    open an elevated Command Prompt (Run as administrator) and run for example:
#        D:\bootstrap.cmd -MastHostName mast05 -RebootAfterBootstrap
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
(until you run `bootstrap.cmd` as Administrator, or `bootstrap.ps1` from an elevated
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
#   2) Run bootstrap: right-click client\bootstrap.cmd (or the copy on D:\ etc.)
#      and choose Run as administrator. For arguments (for example -MastHostName mast05),
#      use an elevated Command Prompt instead:
#         D:\bootstrap.cmd -MastHostName mast05
#      Bootstrap does all first-time prep (mast user, WinRM, OpenSSH, Npcap,
#      rename, WU policy, telemetry/privacy hardening, Windows Firewall OFF);
#      there is no separate prepare step.
#   3) Power off cleanly.

# Take the snapshots:
.\vm\vbox-create-unit.ps1 -SnapshotOnly
```

Either path produces two snapshots: `clean-state` (post-Windows install, before
manual bootstrap) and `post-prepare` (after `bootstrap.cmd` (Run as
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
- `C:\MAST\src\` holds the role's clones (`common\`, `unit\`, `claude\`) and one venv at `C:\MAST\src\.venv`
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

**`always` (optional)** — `"always": true` marks a module that must run on **every**
non-empty provisioning run, not only when it drifted. Set it on order-terminal
cross-cutting providers: `reboot` (detect pending-reboot and drop the flag the
orchestrator acts on), `mast-services-standdown` (stand the unit down before anything
else), `mast-services-finalize` (the final posture assertion), and
`proxy` (the end-of-run posture re-assert). `build-mast.ps1` collects these into
`build-manifest.json`'s `always_modules`, and the driver's per-module drift compare
folds them into any non-empty target set — so a targeted update that installed
anything still closes out properly. They never *cause* a run on their own.

**`repofiles` (optional)** — for a file the module runs that deliberately lives
*outside* its provider directory, because it is shared with something else in the
repo:

```json
"repofiles": ["tools/mast-clone.ps1", "tools/mast-repos.tsv"]
```

Paths are relative to the **repo top** and are staged to the staging root **by
leaf name** (the same flattening `assets/*` gets), so the module's `command`
invokes them as `.\mast-clone.ps1`. Use this instead of copying the file into the
provider directory (which forks the shared source of truth) or writing
`../../tools/...` in `commandfiles` (which resolves on the source side but writes
outside the staging root). Absolute paths, `..` segments, and missing files are
build errors — see `build/build-staging-lib.ps1`.

No edit to `execute-mast-provisioning.ps1` is required. `build-mast.ps1` copies `client/run-verify-only.ps1` into each staged `01-provisioning` folder for verify-only reruns.

---

## Secrets / vault

`vault/` is gitignored except for `vault/README.md` and `vault/creds.json.template`.
Never commit secrets, tokens, or `.lic` files.

---

## See also

- [docs/provisioning-server-setup.md](docs/provisioning-server-setup.md) - full installation guide (bare Windows -> running autonomous loop)
- [docs/decisions/](docs/decisions/) - design rationale, one file per decision ([format](docs/decisions/README.md)); where new decisions are recorded
- [docs/decisions/archive-2026-05-04-to-2026-08-03.md](docs/decisions/archive-2026-05-04-to-2026-08-03.md) - the frozen former `DECISIONS.md`: 91 decisions taken 2026-05-04 to 2026-07-29, reverse-chronological (the 27 later entries, written on `eli/provisioning-v3` and unmerged, are individual records)
- [autonomous-provisioning-requirements.md](autonomous-provisioning-requirements.md) - design of the autonomous loop
- [unit-config-open-questions.md](unit-config-open-questions.md) - open questions on per-unit MongoDB `UnitConfig` fields
