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
|   |-- bootstrap-winrm.ps1           # First-time unit setup: mast user, WinRM HTTP
|   |-- prepare-mast-client.ps1       # Second-stage: hostname, WinRM HTTPS, WU policy
|   |-- execute-mast-provisioning.ps1 # Runs on the unit; iterates through commands.json
|   |-- run-verify-only.ps1           # Runs on the unit; *-verify steps only (see below)
|   `-- onboard-mast-unit.ps1         # One-shot Stages 0-5 bootstrap for a new unit
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

| Order | Module       | Description                                  |
|------:|--------------|----------------------------------------------|
|    10 | `cygwin`     | Cygwin environment (prebuilt tgz)            |
|    20 | `python`     | Python 3.12 + virtualenv                     |
|    30 | `ascom`      | ASCOM Platform 7.1.0 + Developer tools       |
|    40 | `mongodb`    | MongoDB client tools                         |
|    50 | `wireshark`  | Wireshark network analyzer                   |
|    60 | `nssm`       | Non-Sucking Service Manager                  |
|    70 | `nomachine`  | NoMachine + license                          |
|    80 | `mast`       | Clone MAST repos, install requirements       |
|    90 | `phd2`       | PHD2 telescope autoguiding                   |
|   100 | `stage`      | Optical stage control                        |
|   110 | `planewave`  | PlaneWave PWI4 + PS3                         |
|   120 | `zwo`        | ZWO camera drivers                           |
|   130 | `vscode`     | Visual Studio Code                           |
|   140 | `sysinternals`| Sysinternals Suite                          |
|   150 | `chrome`     | Google Chrome                                |

Order numbers leave gaps so new modules can be inserted without renumbering.

---

## Production path (physical unit)

This is the only path operators run by hand. Everything else is autonomous.

1. Plug the unit machine in, install Windows IoT, complete OOBE.
2. Copy `client/onboard-mast-unit.ps1` plus `vault/creds.json` to the unit
   (USB drive or temporary share).
3. On the unit, in an elevated PowerShell:

   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process -Force
   .\onboard-mast-unit.ps1 -HostName mast05 -ProvServer <prov-ip-or-dns>
   ```

   Ensure `mast05` resolves from the provisioning server (DNS or hosts file). Units use DHCP; identity is the hostname, not a fixed IP.

4. The script runs Stages 0-5 (preflight, bootstrap, prepare, provision, register,
   handoff) and exits `ONBOARD_OK`. From here on the prov server's Task Scheduler
   loop manages all updates.

If a stage fails, the script prints a `-ResumeFrom <stage>` command for re-runs.
Logs: `C:\MAST\logs\onboarding\onboarding.log` (mirrored to the prov server
under `C:\MAST\logs\onboarding\<hostname>.log`).

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

# 7) Run prepare-mast-client.ps1 remotely to finish WinRM HTTPS / steady state:
$cred = Get-Credential   # mast / physics
Invoke-Command -ComputerName mast05 -Credential $cred `
    -FilePath .\client\prepare-mast-client.ps1 `
    -ArgumentList @{HostName='mast05'; Provider='192.168.56.1'}

# 8) Power off, snapshot:
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
#      from the host after you run bootstrap + prepare.
#   2) Run bootstrap: right-click client\bootstrap-winrm.cmd (or the copy on D:\ etc.)
#      and choose Run as administrator. For arguments (for example -MastHostName mast05),
#      use an elevated Command Prompt instead:
#         D:\bootstrap-winrm.cmd -MastHostName mast05
#      Then open an elevated PowerShell for prepare:
#         Set-ExecutionPolicy Bypass -Scope Process -Force
#         .\prepare-mast-client.ps1 -HostName mast05 -Provider 192.168.56.1
#   3) Power off cleanly.

# Take the snapshots:
.\vm\vbox-create-unit.ps1 -SnapshotOnly
```

Either path produces two snapshots: `clean-state` (post-Windows install, before or
after manual bootstrap depending when you snapshot) and `post-prepare` (after
`bootstrap-winrm.cmd` (Run as administrator) + `prepare-mast-client` ran).

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
- [docs/provisioning-flow.md](docs/provisioning-flow.md) - protocol and privilege flow diagrams
