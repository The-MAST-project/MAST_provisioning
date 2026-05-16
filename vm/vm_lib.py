"""Shared WinRM / PowerShell helpers for MAST_provisioning/vm/ scripts.

This module is the canonical source of truth for:
  * loading vault credentials
  * constructing a pywinrm Session (do NOT instantiate winrm.Session directly
    elsewhere -- see MAST_provisioning/CLAUDE.md DRY rules)
  * running a PowerShell snippet on a unit with heartbeat logging
  * waiting for WinRM to come back after boot/reboot
  * uploading a text file to a unit via base64 chunking

It is import-pure: importing this module does not touch the filesystem, the
network, or the logger. Long-running orchestrators (run-prov-test.py) can
swap the log sinks by assigning to ``vm_lib.log_fn`` / ``vm_lib.log_raw_fn``
after import; ad-hoc debug scripts can ignore that and get plain timestamped
prints for free.
"""

from __future__ import annotations

import base64
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

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
REPO_ROOT = Path(__file__).resolve().parent.parent
VAULT_CREDS = REPO_ROOT / "vault" / "creds.json"

WINRM_PORT = 5985
WINRM_CALL_TIMEOUT_S = 60 * 60
WINRM_BOOT_TIMEOUT_S = 15 * 60
HEARTBEAT_INTERVAL_S = 30

# VirtualBox -- canonical path on Windows. Override by setting VBOXMANAGE_PATH
# in the environment if VirtualBox is installed elsewhere.
VBOXMANAGE = Path(
    os.environ.get("VBOXMANAGE_PATH")
    or r"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
)
VM_STOP_POLL_TIMEOUT_S = 30


# ---------------------------------------------------------------------------
# Logging hooks -- callers may rebind these
# ---------------------------------------------------------------------------

def _now() -> str:
    return datetime.now(timezone.utc).strftime("%H:%M:%SZ")


def _default_log(msg: str) -> None:
    print(f"[{_now()}] {msg}", flush=True)


def _default_log_raw(text: str) -> None:
    print(text, flush=True)


# Reassign these from a long-running orchestrator to tee into a session log.
log_fn: Callable[[str], None] = _default_log
log_raw_fn: Callable[[str], None] = _default_log_raw


def _log(msg: str) -> None:
    log_fn(msg)


def _log_raw(text: str) -> None:
    log_raw_fn(text)


def _fmt_mmss(seconds: int) -> str:
    if seconds < 60:
        return f"{seconds}s"
    return f"{seconds // 60:02d}:{seconds % 60:02d}"


# ---------------------------------------------------------------------------
# PS string helpers
# ---------------------------------------------------------------------------

def _ps_escape(s: str) -> str:
    """Escape a value for embedding inside a PowerShell single-quoted string."""
    return s.replace("'", "''")


# ---------------------------------------------------------------------------
# Credentials / WinRM
# ---------------------------------------------------------------------------

def load_creds() -> dict[str, dict[str, str]]:
    if not VAULT_CREDS.exists():
        raise RuntimeError(
            f"Credentials file not found: {VAULT_CREDS}\n"
            "Create vault/creds.json with the format:\n"
            '  { "unit": { "user": ".\\\\mast", "pass": "..." } }'
        )
    return json.loads(VAULT_CREDS.read_text(encoding="utf-8"))


def winrm_session(
    host: str,
    cred: dict[str, str],
    read_timeout_s: int | None = None,
    op_timeout_s: int | None = None,
) -> winrm.Session:
    return winrm.Session(
        f"http://{host}:{WINRM_PORT}/wsman",
        auth=(cred["user"], cred["pass"]),
        transport="basic",
        read_timeout_sec=read_timeout_s if read_timeout_s is not None else WINRM_CALL_TIMEOUT_S + 30,
        operation_timeout_sec=op_timeout_s if op_timeout_s is not None else WINRM_CALL_TIMEOUT_S,
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
    step_timer: list[float] | None = None,
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
            now = time.monotonic()
            elapsed = int(now - start)
            step_start = step_timer[0] if step_timer is not None else start
            step = int(now - step_start)
            _log(f"  ... {label} still running ({_fmt_mmss(elapsed)} elapsed, step {_fmt_mmss(step)})")
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
    step_timer: list[float] | None = None,
) -> winrm.Response:
    """Run a PowerShell script via WinRM with heartbeat logging and a hard timeout."""
    tag = f"[{label}] " if label else ""
    if echo:
        _log(f"{tag}>>> {script[:120].rstrip()}")
    r = _run_with_heartbeat(
        lambda: session.run_ps(script),
        label=f"{tag}run_ps",
        timeout_s=timeout_s,
        step_timer=step_timer,
    )
    if r.std_out:
        _log_raw(r.std_out.decode(errors="replace").rstrip())
    if r.std_err:
        brief = _format_winrm_stderr(r.std_err.decode(errors="replace"))
        if brief:
            _log_raw(f"[stderr] {brief}")
    return r


def check_rc(r: winrm.Response, phase: str) -> None:
    if r.status_code != 0:
        raise RuntimeError(f"{phase} failed with exit code {r.status_code}")


def wait_for_winrm(host: str, cred: dict[str, str], timeout: int = WINRM_BOOT_TIMEOUT_S) -> None:
    _log(f"Waiting for WinRM on {host} (up to {timeout}s)...")
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
                        _log(f"WinRM on {host} is ready (user={usr!r}).")
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
                _log(
                    f"WinRM: TCP {WINRM_PORT} open on {host} but Basic auth not accepted yet ({tail}). "
                    "Confirm vault/creds.json matches the unit mast password and that prepare-mast-client "
                    "finished (HTTPS step can recycle WinRM briefly)."
                )
            else:
                _log(f"WinRM: TCP {WINRM_PORT} not open on {host} yet (still booting or wrong host?).")
            last_diag = now
        time.sleep(5)
    raise TimeoutError(f"WinRM on {host} did not become reachable within {timeout}s")


# ---------------------------------------------------------------------------
# File transfer
# ---------------------------------------------------------------------------

def upload_file_b64(
    session: winrm.Session,
    remote_path: str,
    content: str,
    label: str = "file",
    chunk_size: int = 10000,
) -> None:
    """Upload text content to a Windows path via base64 chunks over WinRM.

    Avoids PowerShell single-quote escaping issues that arise when passing
    raw source files inline. The content is split into chunk_size base64
    segments and reassembled remotely before being decoded and written.
    """
    b64 = base64.b64encode(content.encode("utf-8")).decode("ascii")
    chunks = [b64[i:i + chunk_size] for i in range(0, len(b64), chunk_size)]
    ps_lines = ["$chunks = @()"]
    for chunk in chunks:
        ps_lines.append(f"$chunks += '{chunk}'")
    remote_path_ps = _ps_escape(remote_path)
    ps_lines += [
        "$b64 = [string]::Join('', $chunks)",
        "$bytes = [Convert]::FromBase64String($b64)",
        f"[System.IO.File]::WriteAllBytes('{remote_path_ps}', $bytes)",
        f"Write-Host 'Wrote {_ps_escape(label)} ({len(content)} chars)'",
    ]
    ps = "\n".join(ps_lines)
    r = session.run_ps(ps)
    out = (r.std_out or b"").decode(errors="replace").strip()
    if out:
        _log_raw(out)
    if r.status_code != 0:
        err = (r.std_err or b"").decode(errors="replace").strip()
        raise RuntimeError(f"upload_file_b64 failed for {label}: exit {r.status_code}: {err}")


# ---------------------------------------------------------------------------
# VirtualBox VM state
#
# Canonical helpers for power-state inspection, snapshot management, and the
# stop-restore-start-wait recovery sequence. Both run-prov-test.py and
# test-suite.py use these -- do not reimplement elsewhere.
# ---------------------------------------------------------------------------

def vbox(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    """Run VBoxManage with the given args. Returns CompletedProcess."""
    cmd = [str(VBOXMANAGE), *args]
    return subprocess.run(cmd, check=check, text=True, capture_output=True)


def vm_state(vm: str) -> str:
    """Return the VM's VMState ('poweroff', 'running', 'aborted', 'saved', ...).

    Raises subprocess.CalledProcessError if the VM does not exist (VBoxManage
    exits non-zero on showvminfo for an unknown VM).
    """
    info = vbox("showvminfo", vm, "--machinereadable").stdout
    for line in info.splitlines():
        if line.startswith("VMState="):
            return line.split("=", 1)[1].strip().strip('"')
    return "unknown"


def vbox_snapshot_exists(vm: str, snapshot: str) -> bool:
    """Return True iff the named snapshot exists on the VM. Tolerant of a
    missing VBoxManage binary or a missing VM -- both yield False."""
    try:
        r = subprocess.run(
            [str(VBOXMANAGE), "snapshot", vm, "list", "--machinereadable"],
            check=True, text=True, capture_output=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False
    return f'"{snapshot}"' in r.stdout


def unit_stop(vm: str, timeout_s: int = VM_STOP_POLL_TIMEOUT_S) -> None:
    """Power the VM off if it is running. Polls vm_state() until it reports
    'poweroff', up to timeout_s. Logs (but does not raise) on overrun."""
    state = vm_state(vm)
    if state in ("poweroff", "aborted", "saved"):
        _log(f"VM '{vm}' already stopped (state={state}).")
        return
    _log(f"Stopping VM '{vm}' (state={state})...")
    vbox("controlvm", vm, "poweroff")
    for _ in range(timeout_s):
        if vm_state(vm) == "poweroff":
            return
        time.sleep(1)
    _log(f"WARNING: VM '{vm}' did not report poweroff within {timeout_s}s.")


def unit_reset_to_snapshot(vm: str, snapshot: str) -> None:
    """Restore the VM to the named snapshot. VM must already be stopped."""
    _log(f"Restoring VM '{vm}' to snapshot '{snapshot}'...")
    vbox("snapshot", vm, "restore", snapshot)


def unit_start(vm: str, gui: bool = True) -> None:
    """Start the VM. Defaults to a GUI window (matches existing dev workflow);
    pass gui=False for headless."""
    launch_type = "gui" if gui else "headless"
    _log(f"Starting VM '{vm}' ({launch_type})...")
    vbox("startvm", vm, "--type", launch_type)


def reset_to_clean_snapshot(
    vm: str,
    snapshot: str,
    host_unit: str,
    unit_cred: dict[str, str],
    *,
    settle_s: int = 3,
    winrm_wait_s: int = WINRM_BOOT_TIMEOUT_S,
    gui: bool = True,
) -> None:
    """Stop the VM, restore the snapshot, restart, wait for WinRM.

    Single source of truth for the full recovery sequence. test-suite.py
    calls this as a per-scenario pre-flight; run-prov-test.py's phase_reset
    wraps this in a timed() block.
    """
    unit_stop(vm)
    time.sleep(settle_s)
    unit_reset_to_snapshot(vm, snapshot)
    unit_start(vm, gui=gui)
    wait_for_winrm(host_unit, unit_cred, timeout=winrm_wait_s)
