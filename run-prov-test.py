#!/usr/bin/env python3
"""UTM provisioning test orchestrator.

Drives a full MAST provisioning cycle against two UTM Windows VMs:
  1. BUILD   — prov server builds the staged payload
  2. TRANSFER — staged payload copied to IoT unit via WinRM
  3. EXECUTE  — IoT unit runs execute-mast-provisioning.ps1
  4. VERIFY   — smoke-test markers and pass criteria checked
  5. RESET    — IoT VM stopped (disposable mode discards changes) and restarted

Usage:
    python run-prov-test.py \\
        --host-prov 192.168.64.10 \\
        --host-unit 192.168.64.20 \\
        --hostname mast01 \\
        [--modules python,ascom,mast] \\
        [--repeat 3] \\
        [--rebuild] \\
        [--build-only] \\
        [--build-image] \\
        [--utm-unit-vm "Windows IoT"]

Credentials are read from vault/utm-creds.json (gitignored):
    {
        "prov":  {"user": ".\\mast", "pass": "..."},
        "unit":  {"user": ".\\mast", "pass": "..."},
        "smb":   {"user": "macuser", "pass": "..."}
    }

Dependencies:
    pip install pywinrm
"""

from __future__ import annotations

import argparse
import http.server
import json
import socket
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Generator, TextIO

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
try:
    import winrm  # type: ignore[import]
    from winrm.protocol import Protocol  # noqa: F401
except ImportError:
    sys.exit(
        "ERROR: pywinrm is required.\n"
        "Install it with:  pip install pywinrm\n"
        "Then re-run this script."
    )

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
REPO_ROOT = Path(__file__).parent
VAULT_CREDS = REPO_ROOT / "vault" / "utm-creds.json"
LOG_ROOT = Path.home() / "shared-utm" / "test-runs"
UTMCTL = Path("/Applications/UTM.app/Contents/MacOS/utmctl")
UTM_DOCS = Path.home() / "Library/Containers/com.utmapp.UTM/Data/Documents"
UTM_TEMPLATE = REPO_ROOT / "utm-template"   # config.plist + efi_vars.fd committed to repo

# ISOs used by --build-image
WIN_ISO = Path.home() / "Downloads/ISOs/26100.1742.240906-0331.ge_release_svc_refresh_CLIENT_IOT_LTSC_EVAL_A64FRE_en-us.iso"
UNATTEND_ISO = Path.home() / "Downloads/ISOs/26100.1742.240906-0331.ge_release_svc_refresh_CLIENT_IOT_LTSC_EVAL_A64FRE_en-us-autounattend.iso"
UTM_GUEST_TOOLS_ISO = (
    Path.home()
    / "Library/Containers/com.utmapp.UTM/Data/Library/Application Support"
    / "GuestSupportTools/utm-guest-tools-latest.iso"
)
WIN_TEMPLATE_VM = "Windows"          # UTM VM to clone (empty disk, right QEMU config)
WIN_INSTALL_TIMEOUT_S = 45 * 60     # max time for unattended Windows setup

MAC_SMB_HOST = "192.168.64.1"
PROV_SHARE_DRIVE = "Z:"
PROV_SHARE_UNC = f"\\\\{MAC_SMB_HOST}\\shared-utm"
PROV_REPO_PATH = f"{PROV_SHARE_DRIVE}\\mast-prov"
STAGING_LOCAL = f"{PROV_SHARE_DRIVE}\\staging"

WINRM_PORT = 5985
WINRM_TIMEOUT_S = 90 * 60
WINRM_CALL_TIMEOUT_S = 30 * 60
WINRM_BOOT_TIMEOUT_S = 3 * 60
HEARTBEAT_INTERVAL_S = 30
EXECUTE_POLL_INTERVAL_S = 20  # how often to fetch new log lines during execute

EXPECTED_PYTHON = "C:\\Python312\\python.exe"
EXPECTED_REPOS_ROOT = "C:\\MAST\\repos"
SMOKE_LOG_DIR = "C:\\ProgramData\\MAST\\logs"
EXECUTE_LOG = f"{SMOKE_LOG_DIR}\\provisioning-execute.log"

ALL_MODULES = [
    "ascom", "cygwin", "mast", "mongodb", "nomachine",
    "nssm", "phd2", "planewave", "python", "stage",
    "sysinternals", "vscode", "wireshark", "zwo",
]

# ---------------------------------------------------------------------------
# Logging — tee to file and stdout
# ---------------------------------------------------------------------------
_log_file: TextIO | None = None


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%H:%M:%SZ")


def log(msg: str) -> None:
    line = f"[{_now()}] {msg}"
    print(line, flush=True)
    if _log_file:
        print(line, file=_log_file, flush=True)


def log_raw(text: str) -> None:
    """Print text without timestamp prefix (for forwarded remote output)."""
    print(text, flush=True)
    if _log_file:
        print(text, file=_log_file, flush=True)


@contextmanager
def log_to_file(path: Path) -> Generator[None, None, None]:
    global _log_file
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        _log_file = f
        try:
            yield
        finally:
            _log_file = None


# ---------------------------------------------------------------------------
# Timing
# ---------------------------------------------------------------------------
@contextmanager
def timed(label: str) -> Generator[None, None, None]:
    log(f"\n=== {label} ===")
    t0 = time.monotonic()
    try:
        yield
    finally:
        elapsed = int(time.monotonic() - t0)
        log(f"=== {label} done in {elapsed}s ===")


# ---------------------------------------------------------------------------
# Credentials / WinRM
# ---------------------------------------------------------------------------

def load_creds() -> dict[str, dict[str, str]]:
    if not VAULT_CREDS.exists():
        sys.exit(
            f"ERROR: Credentials file not found: {VAULT_CREDS}\n"
            "Create vault/utm-creds.json with keys: prov, unit, smb.\n"
            "See the script docstring for the expected format."
        )
    return json.loads(VAULT_CREDS.read_text())


def winrm_session(host: str, cred: dict[str, str]) -> winrm.Session:
    return winrm.Session(
        f"http://{host}:{WINRM_PORT}/wsman",
        auth=(cred["user"], cred["pass"]),
        transport="basic",
        read_timeout_sec=WINRM_CALL_TIMEOUT_S + 30,
        operation_timeout_sec=WINRM_CALL_TIMEOUT_S,
    )


def _run_with_heartbeat(
    fn: Any,
    label: str,
    timeout_s: int = WINRM_CALL_TIMEOUT_S,
) -> Any:
    result: list[Any] = []
    exc: list[BaseException] = []

    def worker() -> None:
        try:
            result.append(fn())
        except BaseException as e:
            exc.append(e)

    t = threading.Thread(target=worker, daemon=True)
    start = time.monotonic()
    t.start()
    while t.is_alive():
        t.join(timeout=HEARTBEAT_INTERVAL_S)
        if t.is_alive():
            elapsed = int(time.monotonic() - start)
            log(f"  ... {label} still running ({elapsed}s elapsed)")
            if elapsed >= timeout_s:
                raise TimeoutError(
                    f"{label} exceeded {timeout_s}s timeout — likely hung"
                )
    if exc:
        raise exc[0]
    return result[0]


def run_ps(
    session: winrm.Session,
    script: str,
    *,
    label: str = "",
    timeout_s: int = WINRM_CALL_TIMEOUT_S,
    echo: bool = True,
) -> winrm.Response:
    """Run a PowerShell script via WinRM with heartbeat logging and a hard timeout."""
    tag = f"[{label}] " if label else ""
    if echo:
        log(f"{tag}>>> {script[:120].rstrip()}")
    r = _run_with_heartbeat(
        lambda: session.run_ps(script),
        label=f"{tag}run_ps",
        timeout_s=timeout_s,
    )
    if r.std_out:
        log_raw(r.std_out.decode(errors="replace").rstrip())
    if r.std_err:
        stderr_text = r.std_err.decode(errors="replace").rstrip()
        # Filter noisy CLIXML progress blobs
        if "<Objs" not in stderr_text:
            log_raw(f"[stderr] {stderr_text[:500]}")
    return r


def check_rc(r: winrm.Response, phase: str) -> None:
    if r.status_code != 0:
        raise RuntimeError(f"{phase} failed with exit code {r.status_code}")


def wait_for_winrm(host: str, cred: dict[str, str], timeout: int = WINRM_BOOT_TIMEOUT_S) -> None:
    log(f"Waiting for WinRM on {host} (up to {timeout}s)…")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, WINRM_PORT), timeout=5):
                pass
            s = winrm_session(host, cred)
            r = s.run_cmd("echo", ["ping"])
            if r.status_code == 0:
                log(f"WinRM on {host} is ready.")
                return
        except Exception:
            pass
        time.sleep(5)
    raise TimeoutError(f"WinRM on {host} did not become reachable within {timeout}s")


# ---------------------------------------------------------------------------
# UTM control
# ---------------------------------------------------------------------------

def utmctl(*args: str) -> subprocess.CompletedProcess[str]:
    cmd = [str(UTMCTL), *args]
    return subprocess.run(cmd, check=True, text=True, capture_output=True)


def utm_vm_id(vm_name: str) -> str:
    result = utmctl("list")
    for line in result.stdout.splitlines():
        if vm_name.lower() in line.lower():
            return line.split(":")[0].strip()
    raise ValueError(
        f"UTM VM named '{vm_name}' not found.\n"
        f"Available VMs:\n{result.stdout}"
    )


def utm_stop(vm_name: str) -> None:
    vid = utm_vm_id(vm_name)
    log(f"Stopping UTM VM '{vm_name}' ({vid})…")
    utmctl("stop", vid)


def utm_start(vm_name: str) -> None:
    vid = utm_vm_id(vm_name)
    log(f"Starting UTM VM '{vm_name}' ({vid}) in disposable mode…")
    utmctl("start", "--disposable", vid)


def setup_log_dir(cycle: int) -> Path:
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    log_dir = LOG_ROOT / f"{ts}-cycle{cycle}"
    log_dir.mkdir(parents=True, exist_ok=True)
    return log_dir


# ---------------------------------------------------------------------------
# Build-image phase — create a clean Windows IoT VM from scratch
# ---------------------------------------------------------------------------

# Commands injected into autounattend FirstLogonCommands for the VM build path.
# These mirror what bootstrap-winrm.ps1 does for physical units.
# Each tuple: (order-offset, description, cmd — will be wrapped in cmd /c "...")
_BOOTSTRAP_COMMANDS: list[tuple[int, str, str]] = [
    # Install UTM guest tools (virtio-net driver) — runs first so NIC is up before WinRM.
    # Guest tools ISO is mounted as third CD drive; search common drive letters.
    (1,  "Install UTM guest tools",
         "for %d in (D E F) do if exist %d:\\utm-guest-tools-*.exe (%d:\\utm-guest-tools-*.exe /S)"),
    # mast account (answer file creates it, but ensure password and admin membership)
    (2,  "Set mast password",
         "net user mast physics /add & net localgroup Administrators mast /add"),
    # Windows Update — disable automatic installs and prevent auto-reboot
    (3,  "Disable WU NoAutoUpdate",
         'reg add "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f'),
    (4,  "Disable WU AUOptions",
         'reg add "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU" /v AUOptions /t REG_DWORD /d 1 /f'),
    (5,  "Disable WU NoAutoReboot",
         'reg add "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU" /v NoAutoRebootWithLoggedOnUsers /t REG_DWORD /d 1 /f'),
    (6,  "Disable wuauserv",
         "sc config wuauserv start= disabled & net stop wuauserv"),
    # WinRM
    (7,  "Enable WinRM",             "winrm quickconfig -quiet"),
    (8,  "WinRM basic auth",         'winrm set winrm/config/service/auth @{Basic="true"}'),
    (9,  "WinRM allow unencrypted",  'winrm set winrm/config/service @{AllowUnencrypted="true"}'),
    (10, "WinRM firewall HTTP",
         "netsh advfirewall firewall add rule name=WinRM-HTTP dir=in action=allow protocol=TCP localport=5985"),
    # Reset the 90-day evaluation grace period so the license doesn't expire during testing
    (11, "Rearm evaluation license", "slmgr /rearm"),
]


def _patch_autounattend(src_iso: Path, dst_iso: Path) -> None:
    """Mount src_iso, inject WinRM FirstLogonCommands, write dst_iso."""
    import plistlib, shutil, subprocess, tempfile, xml.etree.ElementTree as ET

    WCM = "http://schemas.microsoft.com/WMIConfig/2002/State"
    UNATTEND_NS = "urn:schemas-microsoft-com:unattend"
    ET.register_namespace("", UNATTEND_NS)
    ET.register_namespace("wcm", WCM)

    with tempfile.TemporaryDirectory() as mount_dir, \
         tempfile.TemporaryDirectory() as work_dir:

        # Mount the source ISO read-only
        subprocess.run(
            ["hdiutil", "attach", "-readonly", "-mountpoint", mount_dir, str(src_iso)],
            check=True, capture_output=True,
        )
        try:
            shutil.copytree(mount_dir, work_dir, dirs_exist_ok=True)
        finally:
            subprocess.run(["hdiutil", "detach", mount_dir], capture_output=True)

        # Find autounattend.xml (case-insensitive)
        xml_path: Path | None = None
        for p in Path(work_dir).iterdir():
            if p.name.lower() == "autounattend.xml":
                xml_path = p
                break
        if xml_path is None:
            raise FileNotFoundError("autounattend.xml not found in the autounattend ISO")

        tree = ET.parse(xml_path)
        root = tree.getroot()

        # Find or create the oobeSystem settings block for Microsoft-Windows-Shell-Setup
        oobe_settings: ET.Element | None = None
        for s in root.findall(f"{{{UNATTEND_NS}}}settings"):
            if s.get("pass") == "oobeSystem":
                for comp in s.findall(f"{{{UNATTEND_NS}}}component"):
                    if "Shell-Setup" in comp.get("name", ""):
                        oobe_settings = comp
                        break
                if oobe_settings is not None:
                    break

        if oobe_settings is None:
            # Create the oobeSystem settings block
            settings_el = ET.SubElement(root, f"{{{UNATTEND_NS}}}settings")
            settings_el.set("pass", "oobeSystem")
            oobe_settings = ET.SubElement(settings_el, f"{{{UNATTEND_NS}}}component")
            oobe_settings.set("name", "Microsoft-Windows-Shell-Setup")
            oobe_settings.set("processorArchitecture", "arm64")
            oobe_settings.set("publicKeyToken", "31bf3856ad364e35")
            oobe_settings.set("language", "neutral")
            oobe_settings.set("versionScope", "nonSxS")
            oobe_settings.set(f"{{{WCM}}}action", "add")

        # Find or create FirstLogonCommands element
        flc = oobe_settings.find(f"{{{UNATTEND_NS}}}FirstLogonCommands")
        if flc is None:
            flc = ET.SubElement(oobe_settings, f"{{{UNATTEND_NS}}}FirstLogonCommands")

        # Find the highest existing order value to avoid collisions
        existing_orders = [
            int(cmd.findtext(f"{{{UNATTEND_NS}}}Order") or 0)
            for cmd in flc.findall(f"{{{UNATTEND_NS}}}SynchronousCommand")
        ]
        base_order = max(existing_orders, default=0)

        for offset, desc, cmd in _BOOTSTRAP_COMMANDS:
            sc = ET.SubElement(flc, f"{{{UNATTEND_NS}}}SynchronousCommand")
            sc.set(f"{{{WCM}}}action", "add")
            ET.SubElement(sc, f"{{{UNATTEND_NS}}}Order").text = str(base_order + offset)
            ET.SubElement(sc, f"{{{UNATTEND_NS}}}CommandLine").text = f"cmd /c \"{cmd}\""
            ET.SubElement(sc, f"{{{UNATTEND_NS}}}Description").text = desc
            ET.SubElement(sc, f"{{{UNATTEND_NS}}}RequiresUserInput").text = "false"

        tree.write(xml_path, encoding="utf-8", xml_declaration=True)

        # Repack as a new ISO (El Torito bootable not needed; Windows only reads the XML)
        subprocess.run(
            [
                "hdiutil", "makehybrid", "-iso", "-joliet",
                "-o", str(dst_iso), work_dir,
            ],
            check=True, capture_output=True,
        )
        log(f"Patched autounattend ISO written to {dst_iso}")


def _utm_bundle(vm_name: str) -> Path:
    """Return the .utm bundle path for a named VM."""
    return UTM_DOCS / f"{vm_name}.utm"


def _utm_config(vm_name: str) -> dict:
    import plistlib
    bundle = _utm_bundle(vm_name)
    config_path = bundle / "config.plist"
    with config_path.open("rb") as f:
        return plistlib.load(f)


def _utm_write_config(vm_name: str, config: dict) -> None:
    import plistlib
    config_path = _utm_bundle(vm_name) / "config.plist"
    with config_path.open("wb") as f:
        plistlib.dump(config, f)


def _utm_uuid(vm_name: str) -> str:
    result = utmctl("list")
    for line in result.stdout.splitlines():
        if vm_name.lower() in line.lower():
            parts = line.split()
            if parts:
                return parts[0].strip()
    raise ValueError(f"UTM VM '{vm_name}' not found")


def phase_build_image(
    unit_vm_name: str,
    host_unit: str,
    unit_cred: dict[str, str],
    hostname: str,
) -> None:
    """Build a clean Windows IoT unit VM from the installation ISO."""
    import plistlib, shutil, tempfile, uuid as _uuid

    with timed("BUILD IMAGE PHASE"):
        # Validate ISOs
        for iso in (UNATTEND_ISO, WIN_ISO):
            if not iso.exists():
                raise FileNotFoundError(f"ISO not found: {iso}")

        # Create a new .utm bundle from scratch — ARM64 Windows config matching
        # the mast-provisioning VM hardware profile.
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        build_name = f"mast-unit-build-{ts}"
        log(f"Creating new UTM bundle '{build_name}'…")
        build_bundle = _utm_bundle(build_name)
        build_bundle.mkdir(parents=True, exist_ok=False)
        data_dir = build_bundle / "Data"
        data_dir.mkdir()

        import plistlib as _pl

        # Load template config and assign fresh UUIDs
        with (UTM_TEMPLATE / "config.plist").open("rb") as f:
            config = _pl.load(f)

        new_uuid = str(_uuid.uuid4()).upper()
        disk_uuid = str(_uuid.uuid4()).upper()
        config["Information"]["UUID"] = new_uuid
        config["Information"]["Name"] = build_name

        # Replace the existing disk drive entry with a fresh qcow2 UUID
        for drive in config.get("Drive", []):
            if drive.get("ImageType") == "Disk":
                drive["Identifier"] = disk_uuid
                drive["ImageName"] = f"{disk_uuid}.qcow2"
                break

        # Copy the seed qcow2 (empty sparse disk from the template VM)
        disk_name = f"{disk_uuid}.qcow2"
        disk_path = data_dir / disk_name
        shutil.copy2(UTM_TEMPLATE / "seed-disk.qcow2", disk_path)
        log(f"Seeded OS disk: {disk_name}")

        # Copy template EFI vars (needed for UEFI boot)
        shutil.copy2(UTM_TEMPLATE / "efi_vars.fd", data_dir / "efi_vars.fd")

        cfg_path = build_bundle / "config.plist"
        with cfg_path.open("wb") as f:
            _pl.dump(config, f)
        log(f"Created VM config (UUID: {new_uuid}).")

        # Patch the autounattend ISO to inject WinRM FirstLogonCommands
        patched_unattend = data_dir / "autounattend-winrm.iso"
        log("Patching autounattend ISO to enable WinRM on first login…")
        _patch_autounattend(UNATTEND_ISO, patched_unattend)

        # Copy the Windows installation ISO into the bundle
        win_dest = data_dir / WIN_ISO.name
        log(f"Copying Windows ISO ({WIN_ISO.stat().st_size // 1_048_576} MB)…")
        shutil.copy2(WIN_ISO, win_dest)

        # Copy guest tools ISO into bundle (provides virtio-net driver on first boot)
        guest_tools_dest = data_dir / UTM_GUEST_TOOLS_ISO.name
        log("Copying UTM guest tools ISO…")
        shutil.copy2(UTM_GUEST_TOOLS_ISO, guest_tools_dest)

        # Patch config.plist: autounattend first, Windows ISO second, guest tools third
        config = _utm_config(build_name)
        cd_drives = [d for d in config.get("Drive", []) if d.get("ImageType") == "CD"]
        if len(cd_drives) < 3:
            raise RuntimeError(
                f"Template VM has {len(cd_drives)} CD drive(s); need at least 3"
            )
        cd_drives[0]["ImageName"] = patched_unattend.name
        cd_drives[1]["ImageName"] = win_dest.name
        cd_drives[2]["ImageName"] = guest_tools_dest.name
        # Force CD boot first and suppress the "press any key" UEFI prompt
        config.setdefault("QEMU", {})["AdditionalArguments"] = ["-boot", "order=d,menu=off"]
        _utm_write_config(build_name, config)
        log("ISOs mounted in VM config.")

        # Register the new bundle with UTM by opening it, then start it.
        # UTM only knows about VMs it has imported; opening the .utm file imports it.
        log(f"Registering '{build_name}' with UTM…")
        subprocess.run(["open", str(build_bundle)], check=True)
        time.sleep(3)  # give UTM a moment to register the VM

        log(f"Starting '{build_name}' ({new_uuid}) for unattended Windows install…")
        utmctl("start", new_uuid)

        # Wait for WinRM — unattended setup enables it via answer file
        log(f"Waiting up to {WIN_INSTALL_TIMEOUT_S // 60} min for Windows setup to complete…")
        wait_for_winrm(host_unit, unit_cred, timeout=WIN_INSTALL_TIMEOUT_S)

        # Upload and run prepare-mast-client.ps1 via HTTP file server
        log("Uploading and running prepare-mast-client.ps1…")
        unit_session = winrm_session(host_unit, unit_cred)
        prepare_src = REPO_ROOT / "client" / "prepare-mast-client.ps1"
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            import shutil as _shutil
            _shutil.copy2(prepare_src, Path(tmpdir) / prepare_src.name)
            srv = _start_file_server(Path(tmpdir))
            try:
                url = f"http://{MAC_TRANSFER_HOST}:{HTTP_TRANSFER_PORT}/{prepare_src.name}"
                run_ps(
                    unit_session,
                    f'Invoke-WebRequest -Uri "{url}" -OutFile "C:\\prepare-mast-client.ps1" -UseBasicParsing',
                    label="fetch-prepare",
                    timeout_s=2 * 60,
                    echo=False,
                )
            finally:
                srv.shutdown()
        run_ps(
            unit_session,
            f'powershell.exe -ExecutionPolicy Bypass -NonInteractive -File "C:\\prepare-mast-client.ps1" -HostName {hostname}',
            label="prepare",
            timeout_s=10 * 60,
        )

        # Eject ISOs and clear build-time boot args so normal runs boot from HDD
        log("Ejecting ISOs from VM config…")
        config = _utm_config(build_name)
        cd_drives = [d for d in config.get("Drive", []) if d.get("ImageType") == "CD"]
        for d in cd_drives:
            d.pop("ImageName", None)
        config.setdefault("QEMU", {})["AdditionalArguments"] = []
        _utm_write_config(build_name, config)

        # Shut down cleanly
        log("Shutting down unit…")
        try:
            run_ps(unit_session, "Stop-Computer -Force", label="shutdown", timeout_s=60)
        except Exception:
            pass
        time.sleep(10)

        # Replace the old mast-unit bundle with the new one.
        # Prefer utmctl delete (cleans up UTM's registry too); fall back to
        # rmtree if the old VM isn't in utmctl's list.
        log(f"Replacing '{unit_vm_name}' with new image…")
        old_bundle = _utm_bundle(unit_vm_name)
        if old_bundle.exists():
            try:
                old_uuid = _utm_uuid(unit_vm_name)
                utmctl("stop", old_uuid)
            except Exception:
                pass
            try:
                old_uuid = _utm_uuid(unit_vm_name)
                utmctl("delete", old_uuid)
                log(f"Deleted old '{unit_vm_name}' via utmctl.")
            except Exception:
                shutil.rmtree(old_bundle)
                log(f"Removed old '{unit_vm_name}' bundle directly.")

        # Rename build bundle → canonical name
        build_bundle.rename(old_bundle)

        # Update name in config.plist (UUID stays as the fresh one we assigned)
        import plistlib as _pl2
        cfg_path2 = old_bundle / "config.plist"
        with cfg_path2.open("rb") as f:
            cfg2 = _pl2.load(f)
        cfg2["Information"]["Name"] = unit_vm_name
        with cfg_path2.open("wb") as f:
            _pl2.dump(cfg2, f)

        log(f"New clean image ready as '{unit_vm_name}' (UUID: {new_uuid}).")


# ---------------------------------------------------------------------------
# Execute-log poller — streams provisioning-execute.log during execute phase
# ---------------------------------------------------------------------------

class ExecuteLogPoller:
    """Background thread that polls provisioning-execute.log on the unit
    and prints new lines to the local console during the execute phase."""

    def __init__(self, host: str, cred: dict[str, str]) -> None:
        self._session = winrm_session(host, cred)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._lines_seen = 0

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=10)

    def _run(self) -> None:
        while not self._stop.wait(timeout=EXECUTE_POLL_INTERVAL_S):
            try:
                r = self._session.run_ps(
                    f"$lines = Get-Content '{EXECUTE_LOG}' -ErrorAction SilentlyContinue; "
                    f"if ($lines) {{ $lines | Select-Object -Skip {self._lines_seen} }}",
                )
                if r.status_code == 0 and r.std_out:
                    new_text = r.std_out.decode(errors="replace").strip()
                    if new_text:
                        new_lines = new_text.splitlines()
                        for line in new_lines:
                            log_raw(f"  [unit] {line}")
                        self._lines_seen += len(new_lines)
            except Exception as e:
                log(f"  [poller] warning: {e}")


# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------

def phase_build(
    prov: winrm.Session,
    hostname: str,
    modules: list[str],
    smb_cred: dict[str, str],
) -> None:
    with timed("BUILD PHASE"):
        if sorted(modules) == sorted(ALL_MODULES):
            modules_arg = ""
        else:
            arr = ",".join(f"'{m}'" for m in modules)
            modules_arg = f" -Modules @({arr})"
        build_cmd = (
            "Set-ExecutionPolicy Bypass -Scope Process -Force; "
            f"Copy-Item -Force '{PROV_SHARE_DRIVE}\\build\\build-mast.ps1' 'C:\\build-mast.ps1'; "
            f"& 'C:\\build-mast.ps1'"
            f" -Top '{PROV_SHARE_DRIVE}'"
            f" -HostName '{hostname}'"
            f"{modules_arg}"
        )
        r = run_ps(prov, build_cmd, label="build", timeout_s=15 * 60)
        check_rc(r, "BUILD")


HTTP_TRANSFER_PORT = 18080
MAC_TRANSFER_HOST = MAC_SMB_HOST


class _FileServer(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt: str, *args: object) -> None:
        pass


def _start_file_server(root: Path) -> http.server.HTTPServer:
    server = http.server.HTTPServer(
        ("", HTTP_TRANSFER_PORT),
        lambda *a, **kw: _FileServer(*a, directory=str(root), **kw),
    )
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return server


def _collect_transfer_files(hostname: str) -> list[tuple[Path, str]]:
    staging = REPO_ROOT / "staging" / hostname / "01-provisioning"
    providers = REPO_ROOT / "server" / "providers"

    if not staging.exists():
        raise RuntimeError(f"Staging directory not found: {staging}")

    files: list[tuple[Path, str]] = []
    seen: set[str] = set()

    commands_json = staging / "commands.json"

    for f in sorted(staging.iterdir()):
        if not f.is_file():
            continue
        if f.stat().st_size < 500:
            content = f.read_bytes()
            if b"git-lfs" in content:
                continue
        files.append((f, f.name))
        seen.add(f.name)

    if commands_json.exists():
        cmds = json.loads(commands_json.read_text(encoding="utf-8-sig"))
        modules_seen: set[str] = set()
        for cmd in cmds:
            mod = cmd.get("module", "")
            if not mod or mod in modules_seen:
                continue
            modules_seen.add(mod)
            mod_dir = providers / mod
            manifest = mod_dir / "module.json"
            if not manifest.exists():
                continue
            mdata = json.loads(manifest.read_text(encoding="utf-8"))
            for cf in mdata.get("commandfiles", []):
                name = Path(cf).name
                if name in seen:
                    continue
                src = mod_dir / cf
                if src.exists() and src.stat().st_size > 500:
                    files.append((src, name))
                    seen.add(name)

    return files


def phase_transfer(
    prov: winrm.Session,
    unit: winrm.Session,
    hostname: str,
    unit_cred: dict[str, str],
    host_unit: str,
) -> None:
    with timed("TRANSFER PHASE"):
        transfer_files = _collect_transfer_files(hostname)
        total_bytes = sum(f.stat().st_size for f, _ in transfer_files)
        log(
            f"{len(transfer_files)} files, {total_bytes / 1_048_576:.1f} MB total  "
            f"via HTTP from {MAC_TRANSFER_HOST}:{HTTP_TRANSFER_PORT}"
        )

        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            serve_root = Path(tmpdir)
            for local, remote_name in transfer_files:
                (serve_root / remote_name).symlink_to(local.resolve())

            log(f"Starting HTTP file server on port {HTTP_TRANSFER_PORT}…")
            server = _start_file_server(serve_root)
            try:
                log("Clearing C:\\mast-staging on unit…")
                r = run_ps(
                    unit,
                    'if (Test-Path "C:\\mast-staging") {'
                    '  cmd /c "rd /s /q C:\\mast-staging" }'
                    'New-Item -ItemType Directory -Force "C:\\mast-staging" | Out-Null;'
                    'Write-Host "mast-staging ready"',
                    label="clear-staging",
                    timeout_s=5 * 60,
                )
                if r.status_code != 0:
                    raise RuntimeError("Failed to prepare C:\\mast-staging on unit")

                base_url = f"http://{MAC_TRANSFER_HOST}:{HTTP_TRANSFER_PORT}"
                t0 = time.monotonic()
                bytes_done = 0
                for idx, (local, remote_name) in enumerate(transfer_files, 1):
                    url = f"{base_url}/{remote_name}"
                    dest = f"C:\\mast-staging\\{remote_name}"
                    size_mb = local.stat().st_size / 1_048_576
                    elapsed = int(time.monotonic() - t0)
                    log(
                        f"  [{idx}/{len(transfer_files)}] {remote_name} "
                        f"({size_mb:.1f} MB)  — {bytes_done / 1_048_576:.0f} MB done, {elapsed}s"
                    )
                    r = run_ps(
                        unit,
                        f'Invoke-WebRequest -Uri "{url}" -OutFile "{dest}" -UseBasicParsing',
                        label="fetch",
                        timeout_s=30 * 60,
                        echo=False,
                    )
                    if r.status_code != 0:
                        raise RuntimeError(
                            f"Transfer failed for {remote_name}: "
                            + r.std_err.decode(errors="replace").strip()
                        )
                    bytes_done += local.stat().st_size
            finally:
                log("Shutting down HTTP file server.")
                server.shutdown()


def phase_execute(unit: winrm.Session, host_unit: str, unit_cred: dict[str, str]) -> winrm.Response:
    with timed("EXECUTE PHASE"):
        log("Starting execute-mast-provisioning.ps1 on unit (up to 90 min)…")
        log(f"Streaming {EXECUTE_LOG} from unit every {EXECUTE_POLL_INTERVAL_S}s…")

        poller = ExecuteLogPoller(host_unit, unit_cred)
        poller.start()
        try:
            execute_cmd = (
                "Set-ExecutionPolicy Bypass -Scope Process -Force; "
                "& 'C:\\mast-staging\\execute-mast-provisioning.ps1' "
                "-StagingPath 'C:\\mast-staging'"
            )
            r = run_ps(unit, execute_cmd, label="execute", timeout_s=WINRM_TIMEOUT_S)
        finally:
            poller.stop()

        if r.status_code != 0:
            log(f"Execute exited with code {r.status_code} — fetching tail of execute log…")
            _fetch_execute_log_tail(unit)

        return r


def _fetch_execute_log_tail(unit: winrm.Session, lines: int = 40) -> None:
    try:
        r = unit.run_ps(
            f"Get-Content '{EXECUTE_LOG}' -ErrorAction SilentlyContinue "
            f"| Select-Object -Last {lines}"
        )
        if r.std_out:
            log(f"--- Last {lines} lines of provisioning-execute.log ---")
            log_raw(r.std_out.decode(errors="replace").rstrip())
            log("--- end ---")
    except Exception as e:
        log(f"Could not fetch execute log: {e}")


def _fetch_diagnostics(unit: winrm.Session) -> None:
    """On failure, collect key diagnostic info from the unit."""
    log("--- Diagnostics ---")
    try:
        # List all smoke files and their content
        r = unit.run_ps(
            f"Get-ChildItem '{SMOKE_LOG_DIR}' -Filter '*-smoke.txt' -ErrorAction SilentlyContinue "
            "| ForEach-Object { \"$($_.Name): $(Get-Content $_.FullName -Raw)\" }"
        )
        if r.std_out:
            log("Smoke files on unit:")
            log_raw(r.std_out.decode(errors="replace").rstrip())

        # List any *-verify.log files (module verification logs)
        r = unit.run_ps(
            f"Get-ChildItem '{SMOKE_LOG_DIR}' -Filter '*-verify.log' -ErrorAction SilentlyContinue "
            "| Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize"
        )
        if r.std_out:
            log("Verify logs on unit:")
            log_raw(r.std_out.decode(errors="replace").rstrip())
    except Exception as e:
        log(f"Diagnostics failed: {e}")
    log("--- end diagnostics ---")


def phase_verify(
    unit: winrm.Session,
    modules: list[str],
    execute_rc: int,
) -> dict[str, Any]:
    with timed("VERIFY PHASE"):
        results: dict[str, Any] = {}

        results["execute_exit_code"] = execute_rc
        results["execute_ok"] = execute_rc == 0

        r = run_ps(unit, f'& "{EXPECTED_PYTHON}" --version', label="python-check")
        results["python_ok"] = r.status_code == 0
        results["python_version"] = (
            r.std_out.decode(errors="replace").strip()
            or r.std_err.decode(errors="replace").strip()
        )

        r = run_ps(unit, f'Test-Path "{EXPECTED_REPOS_ROOT}"', label="repos-root")
        results["repos_root_ok"] = "True" in r.std_out.decode(errors="replace")

        # Read smoke file content; any non-empty content counts as success.
        # Actual values are like "python_ok", "mongodb_ok", etc.
        smoke_checks: dict[str, str | None] = {}
        for mod in modules:
            smoke_path = f"{SMOKE_LOG_DIR}\\{mod}-smoke.txt"
            r = run_ps(
                unit,
                f'Get-Content "{smoke_path}" -ErrorAction SilentlyContinue',
                echo=False,
            )
            content = r.std_out.decode(errors="replace").strip() if r.std_out else None
            smoke_checks[mod] = content if content else None
        results["smoke"] = smoke_checks

        return results


def print_results(results: dict[str, Any], cycle: int) -> bool:
    log(f"\n--- Cycle {cycle} Results ---")
    log(f"  execute exit code : {results['execute_exit_code']}")
    log(
        f"  python check      : {'OK' if results['python_ok'] else 'FAIL'}"
        f" ({results.get('python_version', '')})"
    )
    log(f"  repos root        : {'OK' if results['repos_root_ok'] else 'FAIL'}")
    log("  smoke tests:")
    smoke = results.get("smoke", {})
    for mod, content in smoke.items():
        status = "OK" if content else "FAIL"
        detail = f" ({content})" if content else " (file missing)"
        log(f"    {mod:<20} {status}{detail}")

    passed = (
        results["execute_ok"]
        and results["python_ok"]
        and results["repos_root_ok"]
        and all(v is not None for v in smoke.values())
    )
    log(f"\n  Cycle {cycle}: {'PASS' if passed else 'FAIL'}")
    return passed


def phase_reset(utm_unit_vm: str, host_unit: str, unit_cred: dict[str, str]) -> winrm.Session:
    with timed("RESET PHASE"):
        utm_stop(utm_unit_vm)
        time.sleep(5)
        utm_start(utm_unit_vm)
        wait_for_winrm(host_unit, unit_cred)
        return winrm_session(host_unit, unit_cred)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="MAST UTM provisioning test orchestrator")
    p.add_argument("--host-prov", required=True, help="IP of provisioning server VM")
    p.add_argument("--host-unit", required=True, help="IP of IoT unit VM")
    p.add_argument("--hostname", default="mast01", help="Windows hostname for the unit (default: mast01)")
    p.add_argument("--modules", help="Comma-separated module list (default: all)")
    p.add_argument("--repeat", type=int, default=1, help="Number of test cycles (default: 1)")
    p.add_argument("--rebuild", action="store_true", help="Re-run build phase on every cycle")
    p.add_argument("--build-only", action="store_true", help="Only run the build phase")
    p.add_argument("--utm-unit-vm", default="mast-unit", help="UTM VM name for the IoT unit (default: 'mast-unit')")
    p.add_argument(
        "--build-image",
        action="store_true",
        help="Build a fresh Windows IoT VM from the installation ISO before running the test",
    )
    return p.parse_args()


def main() -> None:
    args = parse_args()
    modules = args.modules.split(",") if args.modules else ALL_MODULES
    creds = load_creds()

    LOG_ROOT.mkdir(parents=True, exist_ok=True)
    run_ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    run_log = LOG_ROOT / f"{run_ts}-run.log"

    with log_to_file(run_log):
        log(f"Run log: {run_log}")
        log(f"Modules: {', '.join(modules)}")
        log(f"Cycles:  {args.repeat}")

        if args.build_image:
            phase_build_image(
                unit_vm_name=args.utm_unit_vm,
                host_unit=args.host_unit,
                unit_cred=creds["unit"],
                hostname=args.hostname,
            )
            # Start the freshly built VM in disposable mode for the test
            utm_start(args.utm_unit_vm)
            wait_for_winrm(args.host_unit, creds["unit"])

        prov_session = winrm_session(args.host_prov, creds["prov"])
        unit_session = winrm_session(args.host_unit, creds["unit"])

        cycle_results: list[bool] = []
        built = False

        for cycle in range(1, args.repeat + 1):
            log(f"\n{'='*60}")
            log(f"CYCLE {cycle}/{args.repeat}")
            log(f"{'='*60}")
            log_dir = setup_log_dir(cycle)

            try:
                if not built or args.rebuild:
                    phase_build(prov_session, args.hostname, modules, creds["smb"])
                    built = True

                if args.build_only:
                    log("--build-only specified; stopping after build.")
                    break

                phase_transfer(prov_session, unit_session, args.hostname, creds["unit"], args.host_unit)

                execute_response = phase_execute(unit_session, args.host_unit, creds["unit"])

                results = phase_verify(unit_session, modules, execute_response.status_code)

                (log_dir / "results.json").write_text(json.dumps(results, indent=2))

                passed = print_results(results, cycle)
                cycle_results.append(passed)

                if not passed:
                    _fetch_diagnostics(unit_session)

            except Exception as exc:
                log(f"\nCycle {cycle} ERROR: {exc}")
                cycle_results.append(False)
                try:
                    _fetch_execute_log_tail(unit_session)
                    _fetch_diagnostics(unit_session)
                except Exception:
                    pass

            if cycle < args.repeat:
                unit_session = phase_reset(args.utm_unit_vm, args.host_unit, creds["unit"])

        if not args.build_only:
            total = len(cycle_results)
            passed_count = sum(cycle_results)
            log(f"\n{'='*60}")
            log(f"SUMMARY: {passed_count}/{total} cycles passed")
            log(f"Run log saved to: {run_log}")
            log(f"{'='*60}")
            sys.exit(0 if passed_count == total else 1)


if __name__ == "__main__":
    main()
