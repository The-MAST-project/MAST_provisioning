# MAST Provisioning

Automated Windows provisioning for MAST telescope unit machines (`mast01`–`mast20`).

## Overview

This system installs and configures all software required to run a MAST unit on a bare Windows machine. It is structured as a **two-machine build-then-execute pipeline**:

1. **Provisioning server** — runs the build script, stages files, and hosts them over SMB or WinRM
2. **Target machine** — receives the staged payload and executes it

In the development/test environment both machines are VirtualBox VMs on a Mac host.

---

## Directory Structure

```
MAST_provisioning/
├── build/
│   ├── build-mast.ps1              # Main build orchestrator — run this on the prov server
│   ├── run-build.ps1               # Quick convenience wrapper
│   └── make-wcd-package.ps1        # WCD package creation (offline provisioning)
├── client/
│   ├── prepare-mast-client.ps1     # Pre-provisioning setup — run on the target
│   └── execute-mast-provisioning.ps1  # Execution engine — run on the target
├── server/
│   ├── lib/
│   │   └── provisioning.psm1       # Shared PowerShell utilities (logging, PATH, services)
│   └── providers/                  # One directory per software module
│       ├── python/
│       │   ├── module.json         # Module manifest (order, command, files, verify)
│       │   ├── provide-python.ps1
│       │   └── assets/
│       │       └── python-3.12.0-amd64.exe
│       └── <module>/               # ascom, cygwin, mast, mongodb, nomachine, nssm, ...
├── vault/                          # Secrets — NOT committed to git
│   ├── tokens/
│   │   └── mast_github.txt         # GitHub PAT with repo read access
│   └── nomachine-licenses/
│       └── *.lic                   # One .lic file per licensed unit
└── staging/                        # Build output — generated, NOT committed
    └── <hostname>/                 # Flat staged payload for that host
        ├── commands.json
        ├── provisioning.psm1
        ├── execute-mast-provisioning.ps1
        └── <module scripts + assets>
```

---

## Module Execution Order

| Order | Module | Description |
|------:|--------|-------------|
| 10 | `cygwin` | Cygwin environment (prebuilt tgz) |
| 20 | `python` | Python 3.12.0 + virtualenv |
| 30 | `ascom` | ASCOM Platform 7.1.0 + Developer tools |
| 40 | `mongodb` | MongoDB client tools (mongosh, Database Tools, Compass) |
| 50 | `wireshark` | Wireshark network analyzer |
| 60 | `nssm` | Non-Sucking Service Manager |
| 70 | `nomachine` | NoMachine Enterprise Client/Desktop + license |
| 80 | `mast` | Clone MAST repos, create virtualenvs, install requirements |
| 90 | `phd2` | PHD2 telescope autoguiding |
| 100 | `stage` | Optical stage control software |
| 110 | `planewave` | PlaneWave PWI4 + PS3 CLI tools |
| 120 | `zwo` | ZWO camera drivers |
| 130 | `vscode` | Visual Studio Code |
| 140 | `sysinternals` | Sysinternals Suite |

Each module declares its own install command and an optional smoke-test command in `module.json`.

---

## Prerequisites

### Vault (required before running the build)

Create `vault/` at the repo root (it is gitignored):

```
vault/
  tokens/
    mast_github.txt      ← GitHub PAT (repo scope, read-only is fine)
  nomachine-licenses/
    <name>.lic           ← One file per licensed unit
```

### Provisioning server requirements

- Windows 10/11 with PowerShell 5.1+
- Administrator privileges
- Network access to the target (host-only subnet in VirtualBox dev setup)
- MAST_provisioning repo accessible (VirtualBox Shared Folder recommended)

### Target machine requirements

- Windows 10/11 or Windows IoT Enterprise
- Administrator access for initial prep script
- WinRM enabled (handled by `prepare-mast-client.ps1`)

---

## Step-by-Step: UTM Dev Setup (current)

### 1. Networking (one-time)

In UTM → each VM → Network, set the adapter to **Shared Network** (UTM's default). Both VMs and
the Mac host share the `192.168.64.0/24` subnet; the Mac host is always `192.168.64.1`.

Assign static IPs inside each Windows VM (Control Panel → Network → adapter properties → IPv4):
- Provisioning server: `192.168.64.10 / 255.255.255.0`, gateway `192.168.64.1`
- IoT unit: `192.168.64.20 / 255.255.255.0`, gateway `192.168.64.1`

Keep a NAT adapter (or use the same Shared Network adapter) for internet access — Shared Network
already provides outbound internet via the Mac.

### 1a. Windows 11 ARM64 ISO

Download from: https://www.microsoft.com/en-us/software-download/windows11arm64

This is the full ARM64 image (not evaluation). No product key is needed to run — Windows operates
fully without activation; only cosmetic restrictions apply (desktop watermark, wallpaper locked).
PowerShell, SMB, WinRM, and all provisioning tooling work without a license.

### 2. Share the repo directory from the Mac

Enable macOS File Sharing for `~/shared-utm`:

```
System Settings → General → Sharing → File Sharing → add ~/shared-utm
```

Create a symlink so the repo is accessible at the expected path inside the share:

```bash
ln -s /path/to/MAST_provisioning ~/shared-utm/mast-prov
```

On the provisioning server VM (as Administrator), mount it as `Z:`:

```powershell
net use Z: \\192.168.64.1\shared-utm /user:MACHOST\<mac-username> <password> /persistent:yes
```

All edits on the Mac are immediately visible inside the VM at `Z:\mast-prov\`.

### 3. Enable WinRM on the provisioning server (one-time)

```powershell
# On provisioning server, as Administrator
winrm quickconfig -quiet
winrm set winrm/config/client/auth '@{Basic="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
netsh advfirewall firewall add rule name="WinRM" dir=in action=allow protocol=TCP localport=5985
```

WinRM on the IoT VM is handled by `prepare-mast-client.ps1` (see Running the Provisioning below).

### 4. Create the IoT VM baseline (one-time)

1. Boot the clean Windows IoT VM.
2. Run `prepare-mast-client.ps1` (see Step 1 of Running the Provisioning).
3. Confirm WinRM is reachable from the Mac: `nc -zv 192.168.64.20 5985`.
4. In UTM → IoT VM → Snapshots, take a snapshot named `post-prepare`.
5. Enable **Disposable Mode** on the IoT VM (UTM 4+): UTM → VM → Edit → check *Run in Disposable
   Mode*. With this enabled, every shutdown discards all changes — the VM always boots from
   the `post-prepare` baseline without manual snapshot restore.

### 5. Create vault/utm-creds.json

```json
{
    "prov":  {"user": ".\\mast", "pass": "<prov-server-mast-password>"},
    "unit":  {"user": ".\\mast", "pass": "<unit-mast-password>"},
    "smb":   {"user": "<mac-username>", "pass": "<mac-login-password>"}
}
```

This file is gitignored (`vault/` is never committed).

### 6. Install pywinrm on the Mac

```bash
pip install pywinrm
```

### 7. Running the automated test

```bash
# Single full cycle
python MAST_provisioning/run-prov-test.py \
    --host-prov 192.168.64.10 \
    --host-unit 192.168.64.20 \
    --hostname mast01

# Three back-to-back cycles (IoT VM auto-resets between runs)
python MAST_provisioning/run-prov-test.py \
    --host-prov 192.168.64.10 \
    --host-unit 192.168.64.20 \
    --hostname mast01 \
    --repeat 3

# Build only (no execution on unit)
python MAST_provisioning/run-prov-test.py \
    --host-prov 192.168.64.10 \
    --host-unit 192.168.64.20 \
    --hostname mast01 \
    --build-only
```

Run logs are written to `~/shared-utm/test-runs/<timestamp>-cycle<N>/results.json`.

---

## Step-by-Step: VirtualBox Dev Setup (legacy)

> This section documents the original VirtualBox-based workflow. The active dev environment is
> now UTM (see above).

### 1. Networking (one-time)

In VirtualBox → File → Host Network Manager, create a host-only network:
- Subnet: `192.168.56.0/24`, DHCP enabled
- Assign to **both VMs** as Adapter 2; keep Adapter 1 as NAT for internet

### 2. Mount the repo in the provisioning server VM

In the provisioning server VM settings → Shared Folders, add:
- Host path: path to this `MAST_provisioning/` directory
- Name: `mast-prov`

Then in the VM:
```powershell
net use Z: \\vboxsvr\mast-prov
```

### 3. Snapshot the target VM

Before any provisioning attempt, snapshot the clean Windows IoT state:

```bash
# On Mac
VBoxManage snapshot "mast01" take "clean-state" --description "Pre-provisioning baseline"
```

**Reset after a failed attempt:**
```bash
VBoxManage controlvm "mast01" poweroff
VBoxManage snapshot "mast01" restore "clean-state"
VBoxManage startvm "mast01" --type gui
```

After `prepare-mast-client.ps1` runs cleanly once, take a second snapshot (`post-prepare`) to skip that step on future resets.

---

## Running the Provisioning

### Step 1 — Prepare the target (run on target VM, as Administrator)

```powershell
.\client\prepare-mast-client.ps1 -HostName mast01 -Provider <prov-server-ip>
```

This sets the hostname, creates the local `mast` admin user, enables WinRM with HTTPS, and opens firewall ports. A reboot is required if the hostname changed.

### Step 2 — Build the staging payload (run on provisioning server, as Administrator)

```powershell
# Full build (all modules)
powershell.exe -ExecutionPolicy Bypass -File Z:\build\build-mast.ps1 -Top Z:\ -HostName mast01

# Subset — e.g. skip nomachine if no license available yet
powershell.exe -ExecutionPolicy Bypass -File Z:\build\build-mast.ps1 -Top Z:\ -HostName mast01 `
    -Modules python,ascom,mongodb,nssm,mast,cygwin,sysinternals,vscode
```

Output: `staging/mast01/` with all scripts, assets, and `commands.json`.

### Step 3 — Execute on the target

**Option A — SMB mount (simpler):**

On the target VM, mount the staging share and run:
```powershell
net use Z: \\<prov-server-ip>\mast-staging /user:.\mast <password>
powershell.exe -ExecutionPolicy Bypass -NonInteractive `
    -File Z:\mast01\execute-mast-provisioning.ps1 -StagingPath Z:\mast01
```

**Option B — WinRM remote (from provisioning server):**

```powershell
$cred = Get-Credential   # .\mast credentials for the target
$sopts = New-PSSessionOption -SkipCACheck -SkipCNCheck
$s = New-PSSession -ComputerName <target-ip> -UseSSL -Credential $cred -SessionOption $sopts

Copy-Item -Path "Z:\staging\mast01" -Destination "C:\mast-staging" -ToSession $s -Recurse -Force

Invoke-Command -Session $s -ScriptBlock {
    powershell.exe -ExecutionPolicy Bypass -NonInteractive `
        -File "C:\mast-staging\execute-mast-provisioning.ps1" `
        -StagingPath "C:\mast-staging"
}
```

---

## Monitoring and Verification

**Live log** (on target during execution):
```
C:\ProgramData\MAST\logs\provisioning-execute.log
```

**Smoke test markers** (written per module on success):
```
C:\ProgramData\MAST\logs\<module>-smoke.txt   → contains "success"
```

**Remote log tail** (from provisioning server):
```powershell
Invoke-Command -Session $s -ScriptBlock {
    Get-Content "C:\ProgramData\MAST\logs\provisioning-execute.log" | Select-Object -Last 40
}
```

**Minimal pass criteria:**
- `execute-mast-provisioning.ps1` exits 0
- `C:\Python312\python.exe --version` succeeds
- `C:\MAST\repos\` contains cloned repos with `.venv\` virtualenvs
- All `*-smoke.txt` files present

---

## Adding or Modifying a Module

1. Create `server/providers/<module>/module.json`:
   ```json
   {
     "name": "mymodule",
     "description": "Human-readable description.",
     "order": 150,
     "command": "powershell.exe -ExecutionPolicy Bypass -NonInteractive -File \".\\provide-mymodule.ps1\"",
     "commandfiles": ["provide-mymodule.ps1", "assets/installer.exe"],
     "verify": "powershell.exe ... smoke test ..."
   }
   ```
2. Add install script to `server/providers/<module>/provide-mymodule.ps1`
3. Drop binary assets into `server/providers/<module>/assets/`
4. Add the module name to the `-Modules` list when calling `build-mast.ps1`

---

## Secrets and gitignore

`vault/` must never be committed. Ensure `.gitignore` contains:
```
vault/
staging/
```
