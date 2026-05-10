# MAST Provisioning

Automated Windows provisioning for MAST telescope unit machines (`mast01`-`mast20`).

## Overview

The provisioning server (a long-lived Windows machine) builds a per-unit staging
payload from this repo, then pushes it to each unit machine via WinRM and runs the
provisioning script on the unit. Modules are self-describing via `module.json`
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
|          -> WinRM push to unit    |
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
|   |-- build-mast.ps1                # Builds staging\<host>\01-provisioning\
|   |-- run-build.ps1                 # Convenience wrapper
|   `-- make-wcd-package.ps1          # Offline (Windows Configuration Designer) package
|-- client/
|   |-- bootstrap-winrm.ps1           # Run once on a fresh unit (mast user, WinRM)
|   |-- prepare-mast-client.ps1       # Run after bootstrap (hostname, HTTPS, WU policy)
|   |-- execute-mast-provisioning.ps1 # Runs on the unit; iterates through commands.json
|   `-- onboard-mast-unit.ps1         # One-shot Stages 0-5 bootstrap for a new unit
|-- server/
|   |-- lib/provisioning.psm1         # Shared PS helpers
|   |-- providers/<module>/...        # Per-module install logic + assets
|   |-- check-and-provision.ps1       # Autonomous loop -- the production driver
|   |-- install-scheduled-task.ps1    # Wires check-and-provision.ps1 into Task Scheduler
|   `-- unit-registry.json.template   # Per-unit metadata, copy to unit-registry.json
|-- tools/
|   `-- unit/vm-fix-winrm.ps1         # Break-glass WinRM recovery (run locally on unit)
|-- vault/                            # Secrets, gitignored
|   |-- creds.json                    # WinRM credentials for units
|   |-- tokens/mast_github.txt        # GitHub PAT
|   `-- nomachine-licenses/*.lic
|-- staging/<host>/01-provisioning/   # Build output, gitignored
|-- admin-prep.ps1                    # One-time elevated host prep (PATH, firewall)
|-- vbox-create-unit.ps1              # Helper to create the dev VirtualBox VM
|-- build-autounattend-iso.ps1        # Builds an Autounattend ISO for unattended Windows install
|-- run-prov-test.py                  # Throwaway test orchestrator (dev only)
|-- DECISIONS.md
|-- autonomous-provisioning.md
`-- README.md
```

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
Logs: `C:\ProgramData\MAST\logs\onboarding.log` (mirrored to the prov server
under `C:\ProgramData\MAST\logs\onboarding\<hostname>.log`).

---

## Autonomous loop on the prov server

After the first successful onboarding, the prov server installs and enables the
Task Scheduler job that runs every 30 min:

```powershell
# On the prov server, as Administrator:
.\server\install-scheduled-task.ps1
Start-ScheduledTask -TaskName MAST-CheckAndProvision   # run once now
Get-ScheduledTask    -TaskName MAST-CheckAndProvision | Get-ScheduledTaskInfo
```

Each run:
1. Reads `server/unit-registry.json` for the unit list.
2. For every reachable unit: builds the latest staging payload, compares its
   `build-manifest.json` `payload_hash` against the unit's
   `C:\ProgramData\MAST\installed-manifest.json`, and skips if matching.
3. Otherwise WinRM-pushes the staged payload to `C:\mast-staging` on the unit
   and runs `execute-mast-provisioning.ps1`.
4. Verifies smoke markers and writes structured logs to
   `C:\ProgramData\MAST\logs\prov\run-<ts>.log` and `activity.csv`.

See `autonomous-provisioning.md` for the full design (log schema, availability
contract, maintenance windows).

---

## Dev/test loop (Windows host + VirtualBox VM)

This is the bring-up loop used while debugging modules; the throwaway Python
orchestrator (`run-prov-test.py`) drives it.

### One-time host setup

```powershell
# Non-elevated:
winget install Python.Python.3.12   # if not already installed
pip install pywinrm

# Elevated (once):
.\admin-prep.ps1                     # adds VBox + Python to Machine PATH, opens ICMP
```

Then create `vault/creds.json` from `vault/creds.json.template`:

```json
{ "unit": { "user": ".\\mast", "pass": "physics" } }
```

### One-time unit VM setup

Two paths: an unattended path (recommended) and a manual path.

#### Unattended (no operator interaction during install)

```powershell
# 1) Build a small autounattend ISO (~1 MB). It contains Autounattend.xml plus
#    bootstrap-winrm.ps1, executed on first auto-logon.
.\build-autounattend-iso.ps1
# Optional: target ARM64 IoT LTSC and pick a specific edition
# .\build-autounattend-iso.ps1 -Architecture arm64 -WindowsEdition "Windows 11 IoT Enterprise LTSC"

# 2) Create the VM with both ISOs mounted:
.\vbox-create-unit.ps1 -IsoPath C:\path\to\Win11_or_IoTLTSC.iso `
                       -AutounattendIso .\autounattend-mast.iso

# 3) Start with GUI and wait ~15-25 min:
VBoxManage startvm mast-unit --type gui

# 4) bootstrap-winrm.ps1 leaves networking on DHCP and brings up WinRM. Confirm
#    reachability by hostname once DNS or hosts maps mast01 to the VM address:
Test-NetConnection mast01 -Port 5985

# 5) Run prepare-mast-client.ps1 remotely to finish hostname + WinRM HTTPS:
$cred = Get-Credential   # mast / physics
Invoke-Command -ComputerName mast01 -Credential $cred `
    -FilePath .\client\prepare-mast-client.ps1 `
    -ArgumentList @{HostName='mast01'; Provider='192.168.56.1'}

# 6) Power off, snapshot:
.\vbox-create-unit.ps1 -SnapshotOnly
```

Defaults baked into the answer file: `mast` / `physics`, `en-US`, `Israel
Standard Time`. Override via parameters on `build-autounattend-iso.ps1`.

#### Manual (walk through Windows setup yourself)

```powershell
# Create the VM (no Windows install yet):
.\vbox-create-unit.ps1 -IsoPath C:\path\to\Win11_or_IoTLTSC.iso

# Start it and walk through Windows setup interactively:
VBoxManage startvm mast-unit --type gui

# Inside the VM after first login:
#   1) Ensure the host-only adapter has an address (DHCP on the VirtualBox
#      host-only network, or set a temporary address) and that mast01 resolves
#      from the host after prepare-mast-client runs.
#   2) Open admin PowerShell:
#         Set-ExecutionPolicy Bypass -Scope Process -Force
#         .\bootstrap-winrm.ps1
#         .\prepare-mast-client.ps1 -HostName mast01 -Provider 192.168.56.1
#   3) Power off cleanly.

# Take the snapshots:
.\vbox-create-unit.ps1 -SnapshotOnly
```

Either path produces two snapshots: `clean-state` (post-Windows install, no MAST
tools) and `post-prepare` (after `bootstrap-winrm` + `prepare-mast-client` ran).

### Run a test cycle

```powershell
# Single cycle, all modules (--host-unit is the WinRM target: hostname preferred):
python .\run-prov-test.py --host-unit mast01 --hostname mast01

# Just the build (no transfer / execute):
python .\run-prov-test.py --host-unit mast01 --hostname mast01 --build-only

# Three cycles, restoring the post-prepare snapshot between each:
python .\run-prov-test.py --host-unit mast01 --hostname mast01 --repeat 3

# Subset of modules (faster iteration on a single problem):
python .\run-prov-test.py --host-unit mast01 --hostname mast01 --modules python,mast
```

Logs land in `test-runs/<timestamp>-cycle<N>/results.json`.

---

## Smoke / verify

- `execute-mast-provisioning.ps1` exits 0
- `C:\Python312\python.exe --version` succeeds
- `C:\MAST\repos\` exists and has cloned repos with virtualenvs
- Every module wrote a non-empty `C:\ProgramData\MAST\logs\<module>-smoke.txt`
- `C:\ProgramData\MAST\installed-manifest.json` exists and matches the build's
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

No edit to `build-mast.ps1` or `execute-mast-provisioning.ps1` is required.

---

## Secrets / vault

`vault/` is gitignored except for `vault/README.md` and `vault/creds.json.template`.
Never commit secrets, tokens, or `.lic` files.

---

## See also

- [DECISIONS.md](DECISIONS.md) - architecture decisions, in chronological order
- [autonomous-provisioning.md](autonomous-provisioning.md) - design of the autonomous loop
