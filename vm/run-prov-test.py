#!/usr/bin/env python3
"""VirtualBox provisioning test orchestrator (Windows host edition).

This is throwaway test scaffolding for the Stage C/D bring-up of MAST
provisioning on a Windows 11 host with a single VirtualBox unit VM.
It is retired once `server/check-and-provision.ps1` (the autonomous
driver) is working - see autonomous-provisioning.md.

Drives a full MAST provisioning cycle:
  1. BUILD    - host runs build-mast.ps1 locally (no VM, no WinRM)
  2. TRANSFER - staged payload pushed to the unit VM via HTTP pull
  3. EXECUTE  - unit runs execute-mast-provisioning.ps1
  4. VERIFY   - smoke-test markers and pass criteria checked
  5. RESET    - unit VM stopped, snapshot restored, restarted

Usage (Windows PowerShell, run from anywhere):
    python MAST_provisioning\\run-prov-test.py ^
        --host-unit mast01 ^
        --hostname  mast01 ^
        [--modules python,ascom,mast] ^
        [--repeat 3] ^
        [--rebuild] ^
        [--build-only] ^
        [--execute-only] ^
        [--vbox-vm mast-unit] ^
        [--snapshot post-prepare]

Credentials read from vault/creds.json (gitignored):
    {
        "unit": {"user": ".\\\\mast", "pass": "..."}
    }

Dependencies:
    pip install pywinrm
"""

from __future__ import annotations

import argparse
import http.server
import json
import re
import socket
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Generator, TextIO

try:
    import winrm  # type: ignore[import]
except ImportError:
    sys.exit(
        "ERROR: pywinrm is required.\n"
        "Install it with:  pip install pywinrm\n"
        "Then re-run this script."
    )

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
REPO_ROOT = Path(__file__).parent.parent
VAULT_CREDS = REPO_ROOT / "vault" / "creds.json"
LOG_ROOT = Path(r"C:\MAST\logs\dev")

VBOXMANAGE = Path(r"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe")

# The Windows host's address on the host-only adapter - the unit pulls
# staging files from us over HTTP on this address.
HOST_TRANSFER_HOST = "192.168.56.1"
HTTP_TRANSFER_PORT = 18080

WINRM_PORT = 5985
WINRM_TIMEOUT_S = 90 * 60
WINRM_CALL_TIMEOUT_S = 30 * 60
# First cycle often waits for the unit after snapshot restore or reboot; auth can lag TCP.
WINRM_BOOT_TIMEOUT_S = 15 * 60
HEARTBEAT_INTERVAL_S = 30
EXECUTE_POLL_INTERVAL_S = 20

EXPECTED_PYTHON = "C:\\Python312\\python.exe"
EXPECTED_REPOS_ROOT = "C:\\MAST\\repos"
MAST_LOGS_BASE = "C:\\MAST\\logs"
SMOKE_LOG_DIR = f"{MAST_LOGS_BASE}\\smoke"
VERIFY_LOG_DIR = f"{MAST_LOGS_BASE}\\verify"

ALL_MODULES = [
    "ascom", "chrome", "cygwin", "mast", "mongodb", "nomachine",
    "nssm", "phd2", "planewave", "python", "stage",
    "sysinternals", "vscode", "wireshark", "zwo",
]

# ---------------------------------------------------------------------------
# Logging - tee to file and stdout
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


def _format_elapsed(seconds: float) -> str:
    if seconds >= 3600:
        h, rem = divmod(int(seconds), 3600)
        m, s = divmod(rem, 60)
        return f"{h}h {m}m {seconds % 60:.1f}s"
    if seconds >= 60:
        return f"{seconds / 60:.2f} min ({seconds:.1f}s)"
    return f"{seconds:.2f}s"


@contextmanager
def timed(label: str) -> Generator[None, None, None]:
    log(f"\n=== {label} ===")
    t0 = time.monotonic()
    try:
        yield
    finally:
        elapsed = time.monotonic() - t0
        log(f"=== {label} done in {_format_elapsed(elapsed)} ===")


# ---------------------------------------------------------------------------
# Credentials / WinRM
# ---------------------------------------------------------------------------

def load_creds() -> dict[str, dict[str, str]]:
    if not VAULT_CREDS.exists():
        sys.exit(
            f"ERROR: Credentials file not found: {VAULT_CREDS}\n"
            "Create vault/creds.json with the format:\n"
            '  { "unit": { "user": ".\\\\mast", "pass": "..." } }'
        )
    return json.loads(VAULT_CREDS.read_text(encoding="utf-8"))


def winrm_session(host: str, cred: dict[str, str]) -> winrm.Session:
    return winrm.Session(
        f"http://{host}:{WINRM_PORT}/wsman",
        auth=(cred["user"], cred["pass"]),
        transport="basic",
        read_timeout_sec=WINRM_CALL_TIMEOUT_S + 30,
        operation_timeout_sec=WINRM_CALL_TIMEOUT_S,
    )


def _dispose_winrm_session(sess: winrm.Session | None) -> None:
    """Close pooled HTTP connections for a pywinrm Session (best-effort)."""
    if sess is None:
        return
    try:
        sess.protocol.transport.close_session()
    except Exception:
        pass


def _candidate_users(host: str, raw_user: str) -> list[str]:
    # vault/creds.json user may be '.\\mast'. pywinrm on some hosts accepts 'mast' instead.
    # Try a small set of common equivalences without guessing domains.
    u = (raw_user or "").strip()
    if not u:
        return []
    candidates: list[str] = [u]
    if u.startswith(".\\"):
        candidates.append(u[2:])
    if "\\" in u:
        candidates.append(u.split("\\")[-1])
    # If host is an IPv4, try <host>\\user (workgroup-style).
    if re.match(r"^\\d{1,3}(\\.\\d{1,3}){3}$", host):
        base = u[2:] if u.startswith(".\\") else (u.split("\\")[-1] if "\\" in u else u)
        candidates.append(f"{host}\\{base}")
    # de-dupe preserving order
    seen: set[str] = set()
    out: list[str] = []
    for c in candidates:
        if c and c not in seen:
            seen.add(c)
            out.append(c)
    return out


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
                    f"{label} exceeded {timeout_s}s timeout - likely hung"
                )
    if exc:
        raise exc[0]
    return result[0]


def _unescape_clixml_fragment(s: str) -> str:
    s = s.replace("_x000D__x000A_", " ").replace("_x000A_", " ").replace("_x000D_", " ")
    return " ".join(s.split())


def _format_winrm_stderr(text: str, max_len: int = 900) -> str:
    """Turn noisy WinRM / CLIXML stderr into one readable line for the host log."""
    t = text.strip()
    if not t:
        return ""
    # Remote PowerShell often prefixes the CLIXML envelope on stderr.
    t = re.sub(r"^#<\s*CLIXML\s*", "", t, flags=re.IGNORECASE).strip()
    if not t:
        return ""

    if "<Objs" in t:
        chunks: list[str] = []
        for tag in ("Error", "Warning"):
            for m in re.findall(rf'<S S="{tag}">(.*?)</S>', t, flags=re.DOTALL):
                chunks.append(_unescape_clixml_fragment(m))
        if chunks:
            t = " ".join(chunks)
        else:
            # Progress / Information CLIXML on stderr (no Error or Warning stream).
            # It duplicates normal host messages and floods the log; drop it.
            return ""

    for marker in ("At line:", "At ", "    + CategoryInfo", "    + FullyQualifiedErrorId"):
        if marker in t:
            t = t.split(marker)[0].rstrip()
            break
    t = " ".join(t.split())
    if len(t) > max_len:
        return t[: max_len - 3] + "..."
    return t


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
        brief = _format_winrm_stderr(r.std_err.decode(errors="replace"))
        if brief:
            log_raw(f"[stderr] {brief}")
    return r


def check_rc(r: winrm.Response, phase: str) -> None:
    if r.status_code != 0:
        raise RuntimeError(f"{phase} failed with exit code {r.status_code}")


def wait_for_winrm(host: str, cred: dict[str, str], timeout: int = WINRM_BOOT_TIMEOUT_S) -> None:
    log(f"Waiting for WinRM on {host} (up to {timeout}s)...")
    deadline = time.monotonic() + timeout
    users = _candidate_users(host, cred.get("user", ""))
    last_diag = 0.0
    while time.monotonic() < deadline:
        tcp_ok = False
        try:
            with socket.create_connection((host, WINRM_PORT), timeout=5):
                tcp_ok = True
        except OSError:
            pass

        auth_errors: list[str] = []
        if tcp_ok:
            for usr in users or [cred.get("user", "")]:
                s: winrm.Session | None = None
                try:
                    s = winrm.Session(
                        f"http://{host}:{WINRM_PORT}/wsman",
                        auth=(usr, cred["pass"]),
                        transport="basic",
                        read_timeout_sec=30,
                        operation_timeout_sec=20,
                    )
                    r = s.run_cmd("echo", ["ping"])
                    if r.status_code == 0:
                        cred["user"] = usr
                        log(f"WinRM on {host} is ready (user={usr!r}).")
                        return
                except Exception as e:
                    auth_errors.append(f"{usr!r}:{type(e).__name__}")
                    continue
                finally:
                    _dispose_winrm_session(s)

        now = time.monotonic()
        if now - last_diag >= 60:
            if tcp_ok:
                tail = "; ".join(auth_errors[-4:]) if auth_errors else "no auth attempts"
                log(
                    f"WinRM: TCP {WINRM_PORT} open on {host} but Basic auth not accepted yet ({tail}). "
                    "Confirm vault/creds.json matches the unit mast password and that prepare-mast-client "
                    "finished (HTTPS step can recycle WinRM briefly)."
                )
            else:
                log(f"WinRM: TCP {WINRM_PORT} not open on {host} yet (still booting or wrong host?).")
            last_diag = now
        time.sleep(5)
    raise TimeoutError(f"WinRM on {host} did not become reachable within {timeout}s")


# ---------------------------------------------------------------------------
# VirtualBox control
# ---------------------------------------------------------------------------

def vbox(*args: str) -> subprocess.CompletedProcess[str]:
    cmd = [str(VBOXMANAGE), *args]
    return subprocess.run(cmd, check=True, text=True, capture_output=True)


def vm_state(vm: str) -> str:
    info = vbox("showvminfo", vm, "--machinereadable").stdout
    for line in info.splitlines():
        if line.startswith("VMState="):
            return line.split("=", 1)[1].strip().strip('"')
    return "unknown"


def unit_stop(vm: str) -> None:
    state = vm_state(vm)
    if state in ("poweroff", "aborted", "saved"):
        log(f"VM '{vm}' already stopped (state={state}).")
        return
    log(f"Stopping VM '{vm}' (state={state})...")
    vbox("controlvm", vm, "poweroff")
    # poll until reported off
    for _ in range(30):
        if vm_state(vm) == "poweroff":
            return
        time.sleep(1)
    log(f"WARNING: VM '{vm}' did not report poweroff within 30s.")


def unit_reset_to_snapshot(vm: str, snapshot: str) -> None:
    log(f"Restoring VM '{vm}' to snapshot '{snapshot}'...")
    vbox("snapshot", vm, "restore", snapshot)


def unit_start(vm: str) -> None:
    log(f"Starting VM '{vm}' (GUI)...")
    vbox("startvm", vm, "--type", "gui")


def setup_log_dir(cycle: int) -> Path:
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    log_dir = LOG_ROOT / f"{ts}-cycle{cycle}"
    log_dir.mkdir(parents=True, exist_ok=True)
    return log_dir


# ---------------------------------------------------------------------------
# Execute-log poller - streams provisioning-execute.log during execute phase
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
        self._thread.join(timeout=15)
        if self._thread.is_alive():
            log(
                "WARNING: ExecuteLogPoller did not stop in time; "
                "leaving poller WinRM session open to avoid races."
            )
            return
        _dispose_winrm_session(self._session)
        self._session = None  # type: ignore[assignment]

    def _run(self) -> None:
        while not self._stop.wait(timeout=EXECUTE_POLL_INTERVAL_S):
            try:
                r0 = self._session.run_ps(
                    "$b = Join-Path $env:SystemDrive 'MAST\\logs\\sessions'; "
                    "$p = ''; "
                    "if (Test-Path $b) { "
                    "  $d = Get-ChildItem -LiteralPath $b -Directory "
                    "    -ErrorAction SilentlyContinue | Sort-Object Name -Descending | "
                    "    Select-Object -First 1; "
                    "  if ($d) { $p = Join-Path $d.FullName 'provisioning-execute.log' } "
                    "}; $p"
                )
                path = (r0.std_out or b"").decode(errors="replace").strip()
                if not path:
                    continue
                r = self._session.run_ps(
                    f"$lines = Get-Content -LiteralPath '{path}' -ErrorAction SilentlyContinue; "
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

def phase_build(hostname: str, modules: list[str]) -> None:
    """Build runs LOCALLY on this Windows host (no VM, no WinRM)."""
    with timed("BUILD PHASE"):
        build_script = REPO_ROOT / "build" / "build-mast.ps1"
        if not build_script.exists():
            raise FileNotFoundError(f"Build script not found: {build_script}")

        cmd = [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", str(build_script),
            "-Top", str(REPO_ROOT),
            "-HostName", hostname,
            # Dev/test: avoid admin-only SMB share creation in build-mast.ps1.
            # Transfer to the unit happens over the embedded HTTP server in this test harness.
            "-SkipSmbShare",
            # Dev/test: allow missing large optional assets and license/token material.
            "-TestMode",
            "-AllowMissingNoMachineLicense",
            "-AllowMissingGithubToken",
        ]
        if sorted(modules) != sorted(ALL_MODULES):
            cmd += ["-Modules", ",".join(modules)]

        log(">>> " + " ".join(cmd))
        proc = subprocess.run(cmd, text=True, capture_output=True)
        if proc.stdout:
            log_raw(proc.stdout.rstrip())
        if proc.stderr:
            log_raw(f"[stderr] {proc.stderr.rstrip()}")
        if proc.returncode != 0:
            raise RuntimeError(f"BUILD failed with exit code {proc.returncode}")


class _FileServer(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt: str, *args: object) -> None:
        pass


def _start_file_server(root: Path) -> tuple[http.server.HTTPServer, threading.Thread]:
    # Bind only to the host-only address so Windows Firewall can scope to 192.168.56.0/24
    # and we do not listen on the public NIC for the same port.
    server = http.server.HTTPServer(
        (HOST_TRANSFER_HOST, HTTP_TRANSFER_PORT),
        lambda *a, **kw: _FileServer(*a, directory=str(root), **kw),
    )
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return server, t


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


def phase_transfer(unit: winrm.Session, hostname: str) -> None:
    with timed("TRANSFER PHASE"):
        transfer_files = _collect_transfer_files(hostname)
        total_bytes = sum(f.stat().st_size for f, _ in transfer_files)
        log(
            f"{len(transfer_files)} files, {total_bytes / 1_048_576:.1f} MB total  "
            f"via HTTP from {HOST_TRANSFER_HOST}:{HTTP_TRANSFER_PORT}"
        )

        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            serve_root = Path(tmpdir)
            for local, remote_name in transfer_files:
                # On Windows, symlinks need either Developer Mode or admin -
                # fall back to hardlink on the same volume, then copy.
                dest = serve_root / remote_name
                try:
                    dest.symlink_to(local.resolve())
                except (OSError, NotImplementedError):
                    try:
                        import os as _os
                        _os.link(str(local.resolve()), str(dest))
                    except OSError:
                        import shutil as _shutil
                        _shutil.copy2(local, dest)

            log(f"Starting HTTP file server on port {HTTP_TRANSFER_PORT}...")
            server, serve_thread = _start_file_server(serve_root)
            try:
                log("Clearing C:\\mast-staging on unit...")
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

                base_url = f"http://{HOST_TRANSFER_HOST}:{HTTP_TRANSFER_PORT}"
                t0 = time.monotonic()
                bytes_done = 0
                for idx, (local, remote_name) in enumerate(transfer_files, 1):
                    url = f"{base_url}/{remote_name}"
                    dest = f"C:\\mast-staging\\{remote_name}"
                    size_mb = local.stat().st_size / 1_048_576
                    elapsed = int(time.monotonic() - t0)
                    log(
                        f"  [{idx}/{len(transfer_files)}] {remote_name} "
                        f"({size_mb:.1f} MB)  -- {bytes_done / 1_048_576:.0f} MB done, {elapsed}s"
                    )
                    r = run_ps(
                        unit,
                        # WebClient with Proxy=null bypasses any institutional
                        # proxy that might intercept 192.168.56.x traffic.
                        f'$wc=[System.Net.WebClient]::new();$wc.Proxy=$null;$wc.DownloadFile("{url}","{dest}")',
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
                try:
                    server.shutdown()
                except Exception as ex:
                    log(f"HTTP server shutdown: {ex}")
                try:
                    server.server_close()
                except Exception:
                    pass
                serve_thread.join(timeout=30)
                if serve_thread.is_alive():
                    log(
                        "WARNING: HTTP staging thread still running after shutdown; "
                        "port may stay busy until the process exits."
                    )


def phase_execute(unit: winrm.Session, host_unit: str, unit_cred: dict[str, str]) -> winrm.Response:
    with timed("EXECUTE PHASE"):
        log("Starting execute-mast-provisioning.ps1 on unit (up to 90 min)...")
        log(
            f"Streaming latest provisioning-execute.log under {MAST_LOGS_BASE}\\sessions "
            f"from unit every {EXECUTE_POLL_INTERVAL_S}s..."
        )

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
            log(f"Execute exited with code {r.status_code} - fetching tail of execute log...")
            _fetch_execute_log_tail(unit)

        return r


def _fetch_execute_log_tail(unit: winrm.Session, lines: int = 40) -> None:
    try:
        r0 = unit.run_ps(
            "$b = Join-Path $env:SystemDrive 'MAST\\logs\\sessions'; "
            "$p = ''; "
            "if (Test-Path $b) { "
            "  $d = Get-ChildItem -LiteralPath $b -Directory "
            "    -ErrorAction SilentlyContinue | Sort-Object Name -Descending | "
            "    Select-Object -First 1; "
            "  if ($d) { $p = Join-Path $d.FullName 'provisioning-execute.log' } "
            "}; $p"
        )
        path = (r0.std_out or b"").decode(errors="replace").strip()
        if not path:
            log("--- provisioning-execute.log not found under sessions ---")
            return
        r = unit.run_ps(
            f"Get-Content -LiteralPath '{path}' -ErrorAction SilentlyContinue "
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
        r = unit.run_ps(
            f"Get-ChildItem '{SMOKE_LOG_DIR}' -Filter '*-smoke.txt' -ErrorAction SilentlyContinue "
            "| ForEach-Object { \"$($_.Name): $(Get-Content $_.FullName -Raw)\" }"
        )
        if r.std_out:
            log("Smoke files on unit:")
            log_raw(r.std_out.decode(errors="replace").rstrip())

        r = unit.run_ps(
            f"Get-ChildItem '{VERIFY_LOG_DIR}' -Filter '*-verify.log' "
            "-ErrorAction SilentlyContinue "
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


def phase_reset(
    vbox_vm: str,
    snapshot: str,
    host_unit: str,
    unit_cred: dict[str, str],
    winrm_wait_s: int = WINRM_BOOT_TIMEOUT_S,
) -> winrm.Session:
    with timed("RESET PHASE"):
        unit_stop(vbox_vm)
        time.sleep(3)
        unit_reset_to_snapshot(vbox_vm, snapshot)
        unit_start(vbox_vm)
        wait_for_winrm(host_unit, unit_cred, timeout=winrm_wait_s)
        return winrm_session(host_unit, unit_cred)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="MAST VirtualBox provisioning test orchestrator (Windows host)")
    p.add_argument(
        "--host-unit",
        required=True,
        help="WinRM target for the unit: hostname (recommended, e.g. mast01) or IPv4 if DNS is unavailable",
    )
    p.add_argument("--hostname", default="mast01", help="Windows hostname for the unit (default: mast01)")
    p.add_argument("--modules", help="Comma-separated module list (default: all)")
    p.add_argument("--repeat", type=int, default=1, help="Number of test cycles (default: 1)")
    p.add_argument("--rebuild", action="store_true", help="Re-run build phase on every cycle")
    p.add_argument("--build-only", action="store_true", help="Only run the build phase")
    p.add_argument(
        "--execute-only",
        action="store_true",
        help="Skip build and transfer; WinRM to the unit and run execute-mast-provisioning.ps1 only "
        "(expects payload already at C:\\mast-staging)",
    )
    p.add_argument("--vbox-vm", default="mast-unit", help="VirtualBox VM name (default: 'mast-unit')")
    p.add_argument("--snapshot", default="post-prepare", help="Snapshot name to restore between cycles (default: 'post-prepare')")
    p.add_argument("--no-reset", action="store_true", help="Do not reset the VM between cycles (debug)")
    p.add_argument(
        "--winrm-wait-seconds",
        type=int,
        default=WINRM_BOOT_TIMEOUT_S,
        metavar="N",
        help="Max seconds to wait for TCP :5985 plus WinRM Basic auth before failing (default: %s)." % WINRM_BOOT_TIMEOUT_S,
    )
    return p.parse_args()


def main() -> None:
    args = parse_args()
    if args.build_only and args.execute_only:
        sys.exit("ERROR: --build-only and --execute-only cannot be used together.")
    modules = args.modules.split(",") if args.modules else ALL_MODULES
    creds = load_creds()
    if "unit" not in creds:
        sys.exit("ERROR: vault/creds.json must contain a 'unit' block.")

    LOG_ROOT.mkdir(parents=True, exist_ok=True)
    run_ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    run_log = LOG_ROOT / f"{run_ts}-run.log"
    run_started = time.monotonic()

    with log_to_file(run_log):
        log(f"Run log: {run_log}")
        log(f"Modules: {', '.join(modules)}")
        log(f"Cycles:  {args.repeat}")
        log(f"VM:      {args.vbox_vm}  (snapshot: {args.snapshot})")
        log(f"Unit WinRM target: {args.host_unit}")
        log(f"WinRM wait: {args.winrm_wait_seconds}s")

        cycle_results: list[bool] = []
        built = False
        unit_session: winrm.Session | None = None

        try:
            for cycle in range(1, args.repeat + 1):
                log(f"\n{'='*60}")
                log(f"CYCLE {cycle}/{args.repeat}")
                log(f"{'='*60}")
                log_dir = setup_log_dir(cycle)

                try:
                    if not args.execute_only and (not built or args.rebuild):
                        phase_build(args.hostname, modules)
                        built = True

                    if args.build_only:
                        log("--build-only specified; stopping after build.")
                        break

                    if unit_session is None:
                        with timed("WAIT FOR WINRM"):
                            wait_for_winrm(args.host_unit, creds["unit"], timeout=args.winrm_wait_seconds)
                        unit_session = winrm_session(args.host_unit, creds["unit"])

                    if args.execute_only:
                        log("--execute-only: skipping build and transfer.")
                    else:
                        phase_transfer(unit_session, args.hostname)

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
                    if unit_session is not None:
                        try:
                            _fetch_execute_log_tail(unit_session)
                            _fetch_diagnostics(unit_session)
                        except Exception:
                            pass

                if cycle < args.repeat and not args.no_reset:
                    prev = unit_session
                    unit_session = phase_reset(
                        args.vbox_vm,
                        args.snapshot,
                        args.host_unit,
                        creds["unit"],
                        winrm_wait_s=args.winrm_wait_seconds,
                    )
                    _dispose_winrm_session(prev)
        finally:
            _dispose_winrm_session(unit_session)

        log(
            f"[TIMING] Total run (run-prov-test.py): "
            f"{_format_elapsed(time.monotonic() - run_started)}"
        )

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
