#!/usr/bin/env python3
"""VirtualBox provisioning test orchestrator (Windows host edition).

This is throwaway test scaffolding for the Stage C/D bring-up of MAST
provisioning on a Windows 11 host with a single VirtualBox unit VM.
It is retired once `server/check-and-provision.ps1` (the autonomous
driver) is working - see autonomous-provisioning.md.

Drives a full MAST provisioning cycle:
  1. BUILD    - host runs build-mast.ps1 locally (no VM, no WinRM)
  2. TRANSFER - staged payload pulled by the unit VM via SMB (net use + robocopy)
  3. EXECUTE  - unit runs execute-mast-provisioning.ps1 (skipped with --build-transfer-verify)
  3b. VERIFY-RUN (optional) - with --build-transfer-verify, unit runs run-verify-only.ps1 instead
  4. VERIFY   - smoke-test markers and pass criteria checked (criteria differ in verify-only mode)
  5. RESET    - unit VM stopped, snapshot restored, restarted

Usage (Windows PowerShell, run from anywhere):
    python MAST_provisioning\\vm\\run-prov-test.py ^
        --host-unit mast01 ^
        --hostname  mast01 ^
        [--modules python,ascom,mast] ^
        [--repeat 3] ^
        [--rebuild] ^
        [--phases build,transfer,execute,verify,reset] ^
        [--build-only] ^
        [--execute-only] ^
        [--build-transfer-verify] ^
        [--vbox-vm mast-unit] ^
        [--snapshot post-prepare]

Phase selection (--phases supersedes --build-only, --execute-only, --build-transfer-verify):
    Valid phase names: build, transfer, execute, verify-run, verify, reset
    Default (no flag): build,transfer,execute,verify,reset

Quick module debug loop (no VM reset between runs):
    python MAST_provisioning\\vm\\run-prov-test.py ^
        --host-unit mast01 --hostname mast01 ^
        --modules stage ^
        --phases build,transfer,execute,verify ^
        --no-reset

Re-run execute + verify only (reuse last transfer, no rebuild):
    python MAST_provisioning\\vm\\run-prov-test.py ^
        --host-unit mast01 --hostname mast01 ^
        --modules stage ^
        --phases execute,verify

Verify current unit state without running anything:
    python MAST_provisioning\\vm\\run-prov-test.py ^
        --host-unit mast01 --phases verify

Credentials read from vault/creds.json (gitignored):
    {
        "unit": {"user": ".\\\\mast", "pass": "..."},
        "smb":  {"user": "mast-transfer", "pass": "..."}
    }

Dependencies:
    pip install pywinrm
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
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

# Hostname of the provisioning server (this machine) as the unit will address it for SMB.
PROV_SERVER = os.environ.get("COMPUTERNAME") or socket.gethostname()

WINRM_PORT = 5985
WINRM_TIMEOUT_S = 90 * 60
WINRM_CALL_TIMEOUT_S = 60 * 60
# First cycle often waits for the unit after snapshot restore or reboot; auth can lag TCP.
WINRM_BOOT_TIMEOUT_S = 15 * 60
HEARTBEAT_INTERVAL_S = 30
EXECUTE_POLL_INTERVAL_S = 20
VERIFY_ONLY_TIMEOUT_S = 30 * 60

EXPECTED_PYTHON = "C:\\Python312\\python.exe"
EXPECTED_REPOS_ROOT = "C:\\MAST\\repos"
CLONE_ROOT = EXPECTED_REPOS_ROOT
PULL_REPOS_SCRIPT = REPO_ROOT / "server" / "providers" / "mast" / "pull-mast-repos.ps1"
MAST_LOGS_BASE = "C:\\MAST\\logs"
SMOKE_LOG_DIR = f"{MAST_LOGS_BASE}\\smoke"
VERIFY_LOG_DIR = f"{MAST_LOGS_BASE}\\verify"

ALL_MODULES = [
    "ascom", "chrome", "cygwin", "git", "mast", "mongodb-client", "nomachine",
    "nssm", "phd2", "planewave", "python", "stage",
    "sysinternals", "vscode", "wireshark", "zwo",
]

VALID_PHASES = frozenset(("build", "transfer", "execute", "verify-run", "verify", "reset"))
DEFAULT_PHASES = frozenset(("build", "transfer", "execute", "verify", "reset"))

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


def _fmt_mmss(seconds: int) -> str:
    if seconds < 60:
        return f"{seconds}s"
    return f"{seconds // 60:02d}:{seconds % 60:02d}"


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
# PS string helpers
# ---------------------------------------------------------------------------

def _ps_escape(s: str) -> str:
    """Escape a value for embedding inside a PowerShell single-quoted string."""
    return s.replace("'", "''")


def _find_unit_log_path(session: winrm.Session, log_filename: str) -> str:
    """Return the full path of log_filename inside the newest sessions/ subdir, or ''."""
    r = session.run_ps(
        "$b = Join-Path $env:SystemDrive 'MAST\\logs\\sessions'; "
        "$p = ''; "
        "if (Test-Path $b) { "
        "  $d = Get-ChildItem -LiteralPath $b -Directory "
        "    -ErrorAction SilentlyContinue | Sort-Object Name -Descending | "
        "    Select-Object -First 1; "
        f"  if ($d) {{ $p = Join-Path $d.FullName '{log_filename}' }} "
        "}; $p"
    )
    return (r.std_out or b"").decode(errors="replace").strip()


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
            log(f"  ... {label} still running ({_fmt_mmss(elapsed)} elapsed, step {_fmt_mmss(step)})")
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
        log(f"{tag}>>> {script[:120].rstrip()}")
    r = _run_with_heartbeat(
        lambda: session.run_ps(script),
        label=f"{tag}run_ps",
        timeout_s=timeout_s,
        step_timer=step_timer,
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
    """Background thread that polls a provisioning session log on the unit
    and prints new lines to the local console during execute or verify-only."""

    # Timeout for each individual poller WinRM call (short - just reading a log file).
    _CALL_TIMEOUT_S = 45

    def __init__(
        self,
        host: str,
        cred: dict[str, str],
        log_filename: str = "provisioning-execute.log",
        step_timer: list[float] | None = None,
    ) -> None:
        self._host = host
        self._cred = cred
        self._session = self._new_session()
        self._log_filename = log_filename
        self._step_timer = step_timer
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._lines_seen = 0

    def _new_session(self) -> winrm.Session:
        return winrm_session(
            self._host, self._cred,
            read_timeout_s=self._CALL_TIMEOUT_S + 10,
            op_timeout_s=self._CALL_TIMEOUT_S,
        )

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
        consecutive_errors = 0
        while not self._stop.wait(timeout=EXECUTE_POLL_INTERVAL_S):
            try:
                path = _find_unit_log_path(self._session, self._log_filename)
                if not path:
                    consecutive_errors = 0
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
                            if self._step_timer is not None and "[Order:" in line:
                                self._step_timer[0] = time.monotonic()
                        self._lines_seen += len(new_lines)
                consecutive_errors = 0
            except Exception as e:
                consecutive_errors += 1
                log(f"  [poller] warning ({consecutive_errors}): {e}")
                _dispose_winrm_session(self._session)
                self._session = None  # type: ignore[assignment]
                try:
                    self._session = self._new_session()
                    log("  [poller] reconnected.")
                except Exception as re:
                    log(f"  [poller] reconnect failed: {re}")
                    self._session = self._new_session()  # will retry next iteration


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


def phase_transfer(
    unit: winrm.Session,
    hostname: str,
    run_id: str,
    smb_user: str,
    smb_pass: str,
) -> str:
    """Pull staging payload from the SMB share to the unit. Returns the unit staging path."""
    with timed("TRANSFER PHASE"):
        staging_dir = REPO_ROOT / "staging" / hostname / "01-provisioning"
        if not staging_dir.exists():
            raise RuntimeError(f"Staging directory not found: {staging_dir}")
        files = [f for f in staging_dir.iterdir() if f.is_file()]
        total_bytes = sum(f.stat().st_size for f in files)
        unit_stage = f"C:\\mast-staging\\{run_id}"
        src_unc = f"\\\\{PROV_SERVER}\\mast-staging\\{hostname}\\01-provisioning"
        smb_pass_ps = _ps_escape(smb_pass)

        log(
            f"{len(files)} files, {total_bytes / 1_048_576:.1f} MB  "
            f"via SMB pull from {src_unc}"
        )

        pull_script = REPO_ROOT / "client" / "mast-pull-staging.ps1"
        raw = pull_script.read_text(encoding="ascii")
        # pywinrm base64-encodes the script for -EncodedCommand, which has an ~8192-char
        # argument limit on the WinRM service. Strip the block comment (.SYNOPSIS) and
        # blank lines to stay under that limit. check-and-provision.ps1 uses
        # Invoke-Command -FilePath which sends the full file without this constraint.
        script_text = re.sub(r'<#.*?#>', '', raw, flags=re.DOTALL)
        script_text = '\n'.join(ln for ln in script_text.splitlines() if ln.strip())

        ps = (
            f"$r=&{{\n{script_text}\n}}"
            f" -ProvServer '{PROV_SERVER}'"
            f" -UnitHostname '{hostname}'"
            f" -SmbUser '{smb_user}'"
            f" -SmbPass '{smb_pass_ps}'"
            f" -UnitStage '{unit_stage}'"
            f" -SrcUNC '{src_unc}'\n"
            f"if(-not $r){{Write-Error 'Transfer: null result from pull script';exit 1}}\n"
            f"if($r.outcome -ne 'OK'){{\n"
            f"    Write-Error \"Transfer failed outcome=$($r.outcome) rc=$($r.rc) $($r.detail)\"\n"
            f"    exit 1\n"
            f"}}\n"
            f"Write-Host 'UNIT_STAGE={unit_stage}'\n"
        )

        log(f"[transfer] mast-pull-staging.ps1 -ProvServer '{PROV_SERVER}' -UnitStage '{unit_stage}'")
        r = run_ps(unit, ps, label="transfer", timeout_s=60 * 60, echo=False)
        if r.status_code != 0:
            raise RuntimeError(f"Transfer failed (exit code: {r.status_code})")
        return unit_stage


def phase_execute(
    unit: winrm.Session,
    host_unit: str,
    unit_cred: dict[str, str],
    staging_path: str,
    modules: list[str] | None = None,
    smb_user: str = "",
    smb_pass: str = "",
) -> winrm.Response:
    with timed("EXECUTE PHASE"):
        log("Starting execute-mast-provisioning.ps1 on unit (up to 90 min)...")
        log(
            f"Streaming latest provisioning-execute.log under {MAST_LOGS_BASE}\\sessions "
            f"from unit every {EXECUTE_POLL_INTERVAL_S}s..."
        )

        smb_pass_ps = _ps_escape(smb_pass)
        step_timer: list[float] = [time.monotonic()]
        poller = ExecuteLogPoller(host_unit, unit_cred, step_timer=step_timer)
        poller.start()
        try:
            execute_cmd = (
                "Set-ExecutionPolicy Bypass -Scope Process -Force; "
                f"& '{staging_path}\\execute-mast-provisioning.ps1' "
                f"-StagingPath '{staging_path}' "
                f"-ProvServer '{PROV_SERVER}' "
                f"-SmbUser '{smb_user}' "
                f"-SmbPass '{smb_pass_ps}'"
            )
            if modules and sorted(modules) != sorted(ALL_MODULES):
                execute_cmd += f" -Modules '{','.join(modules)}'"
            r = run_ps(unit, execute_cmd, label="execute", timeout_s=WINRM_TIMEOUT_S, step_timer=step_timer)
        finally:
            poller.stop()

        if r.status_code != 0:
            log(f"Execute exited with code {r.status_code} - fetching tail of execute log...")
            _fetch_execute_log_tail(unit)

        return r


def phase_run_verify_only(
    unit: winrm.Session,
    host_unit: str,
    unit_cred: dict[str, str],
    staging_path: str,
    modules: list[str] | None = None,
) -> winrm.Response:
    """Run run-verify-only.ps1 on the unit using the given staging path."""
    with timed("VERIFY-RUN PHASE"):
        log("Starting run-verify-only.ps1 on unit (no execute-mast-provisioning.ps1)...")
        log(
            f"Streaming provisioning-verify-only.log under {MAST_LOGS_BASE}\\sessions "
            f"from unit every {EXECUTE_POLL_INTERVAL_S}s..."
        )

        step_timer: list[float] = [time.monotonic()]
        poller = ExecuteLogPoller(
            host_unit, unit_cred,
            log_filename="provisioning-verify-only.log",
            step_timer=step_timer,
        )
        poller.start()
        try:
            verify_cmd = (
                "Set-ExecutionPolicy Bypass -Scope Process -Force; "
                f"& '{staging_path}\\run-verify-only.ps1' "
                f"-StagingPath '{staging_path}'"
            )
            if modules and sorted(modules) != sorted(ALL_MODULES):
                verify_cmd += f" -Modules '{','.join(modules)}'"
            r = run_ps(unit, verify_cmd, label="verify-only", timeout_s=VERIFY_ONLY_TIMEOUT_S, step_timer=step_timer)
        finally:
            poller.stop()

        if r.status_code != 0:
            log(
                f"run-verify-only exited with code {r.status_code} - fetching log tail..."
            )
            _fetch_session_log_tail(unit, "provisioning-verify-only.log")

        return r


def _fetch_session_log_tail(unit: winrm.Session, log_filename: str, lines: int = 40) -> None:
    try:
        path = _find_unit_log_path(unit, log_filename)
        if not path:
            log(f"--- {log_filename} not found under sessions ---")
            return
        r = unit.run_ps(
            f"Get-Content -LiteralPath '{path}' -ErrorAction SilentlyContinue "
            f"| Select-Object -Last {lines}"
        )
        if r.std_out:
            log(f"--- Last {lines} lines of {log_filename} ---")
            log_raw(r.std_out.decode(errors="replace").rstrip())
            log("--- end ---")
    except Exception as e:
        log(f"Could not fetch {log_filename}: {e}")


def _fetch_execute_log_tail(unit: winrm.Session, lines: int = 40) -> None:
    _fetch_session_log_tail(unit, "provisioning-execute.log", lines)


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
    run_rc: int,
    *,
    verify_only: bool = False,
) -> dict[str, Any]:
    with timed("VERIFY PHASE"):
        results: dict[str, Any] = {}
        results["verify_only"] = verify_only

        results["execute_exit_code"] = run_rc
        results["execute_ok"] = run_rc == 0

        if verify_only:
            results["python_ok"] = True
            results["python_version"] = "(skipped in verify-only mode)"
            results["repos_root_ok"] = True
            results["smoke"] = {}
            return results

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
    if results.get("verify_only"):
        log("  mode              : BUILD + TRANSFER + VERIFY-RUN (run-verify-only.ps1)")
        log(f"  verify-only exit  : {results['execute_exit_code']}")
        log(f"  verify-only OK    : {'OK' if results['execute_ok'] else 'FAIL'}")
        passed = bool(results["execute_ok"])
        log(f"\n  Cycle {cycle}: {'PASS' if passed else 'FAIL'}")
        return passed

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


def phase_pull_repos(unit: winrm.Session) -> None:
    """Pull all repos (+ submodules) on the unit in-place. No build or transfer needed."""
    with timed("PULL-REPOS PHASE"):
        if not PULL_REPOS_SCRIPT.exists():
            raise FileNotFoundError(f"pull-mast-repos.ps1 not found: {PULL_REPOS_SCRIPT}")
        raw = PULL_REPOS_SCRIPT.read_text(encoding="ascii")
        # Strip block comments so the encoded command stays under the WinRM 8192-char limit.
        script_text = re.sub(r'<#.*?#>', '', raw, flags=re.DOTALL)
        script_text = '\n'.join(ln for ln in script_text.splitlines() if ln.strip())
        ps = (
            f"&{{\n{script_text}\n}}"
            f" -CloneRoot '{CLONE_ROOT}'\n"
        )
        log(f"[pull-repos] Pulling repos under {CLONE_ROOT} on unit...")
        r = run_ps(unit, ps, label="pull-repos", timeout_s=30 * 60, echo=False)
        if r.status_code != 0:
            raise RuntimeError(f"pull-repos failed with exit code {r.status_code}")


MAST_UNIT_SVC_LOG_DIR = "C:\\MAST\\logs\\mast-unit"
MAST_UNIT_PORT = 8000
MAST_UNIT_STATUS_PATH = "/mast/api/v1/unit/status"
MAST_UNIT_BOOT_TIMEOUT_S = 120


def phase_clear_unit_logs(unit: winrm.Session) -> None:
    """Stop MAST_unit and delete its NSSM stdout/stderr logs so the next run starts clean."""
    with timed("CLEAR UNIT LOGS PHASE"):
        ps = (
            "Stop-Service -Name 'MAST_unit' -Force -ErrorAction SilentlyContinue\n"
            f"$d = '{MAST_UNIT_SVC_LOG_DIR}'\n"
            "foreach ($f in @('stdout.log', 'stderr.log')) {\n"
            "    $p = Join-Path $d $f\n"
            "    if (Test-Path -LiteralPath $p) {\n"
            "        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue\n"
            "        Write-Host \"[clear-unit-logs] deleted $p\"\n"
            "    } else {\n"
            "        Write-Host \"[clear-unit-logs] not found (skipping): $p\"\n"
            "    }\n"
            "}\n"
            "Write-Host '[clear-unit-logs] done'\n"
        )
        r = run_ps(unit, ps, label="clear-unit-logs", timeout_s=60, echo=False)
        if r.status_code != 0:
            log(f"WARNING: clear-unit-logs returned exit code {r.status_code}")


def phase_start_mast_unit(unit: winrm.Session) -> None:
    """Start the MAST_unit service after a pull or rebuild."""
    log("[start-mast-unit] Starting MAST_unit service...")
    r = run_ps(
        unit,
        "Start-Service -Name 'MAST_unit' -ErrorAction SilentlyContinue; "
        "Write-Host '[start-mast-unit] done'",
        label="start-mast-unit",
        timeout_s=60,
        echo=False,
    )
    if r.status_code != 0:
        log(f"WARNING: start-mast-unit returned exit code {r.status_code}")


def phase_wait_for_unit_health(host: str, timeout_s: int = MAST_UNIT_BOOT_TIMEOUT_S) -> None:
    """Poll MAST_unit's status endpoint until it returns a valid CanonicalResponse or timeout."""
    url = f"http://{host}:{MAST_UNIT_PORT}{MAST_UNIT_STATUS_PATH}"
    with timed("UNIT HEALTH CHECK PHASE"):
        log(f"[unit-health] Waiting for {url} (up to {timeout_s}s)...")
        deadline = time.monotonic() + timeout_s
        last_err = ""
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen(url, timeout=5) as resp:
                    body = json.loads(resp.read().decode())
                if "api_version" not in body:
                    raise ValueError(f"missing api_version in response: {body}")
                if body.get("errors"):
                    raise ValueError(f"unit reported errors: {body['errors']}")
                log(f"[unit-health] OK -- api_version={body.get('api_version')!r}")
                return
            except (urllib.error.URLError, OSError, json.JSONDecodeError, ValueError) as e:
                last_err = str(e)
            time.sleep(5)
        raise RuntimeError(
            f"MAST_unit health check timed out after {timeout_s}s. Last error: {last_err}"
        )


def phase_run_rebuild_repos(unit: winrm.Session, staging_path: str) -> winrm.Response:
    """Force-reclone all repos: runs provide-mast.ps1 -Force from the transferred staging dir."""
    with timed("REBUILD-REPOS PHASE"):
        log(
            f"[rebuild-repos] Running provide-mast.ps1 -Force"
            f" -CloneRoot {CLONE_ROOT!r} from {staging_path}..."
        )
        cmd = (
            "Set-ExecutionPolicy Bypass -Scope Process -Force; "
            f"& '{staging_path}\\provide-mast.ps1'"
            f" -Force"
            f" -CloneRoot '{CLONE_ROOT}'"
            f" -AssetsRoot '{staging_path}'"
        )
        r = run_ps(unit, cmd, label="rebuild-repos", timeout_s=WINRM_TIMEOUT_S)
        if r.status_code != 0:
            raise RuntimeError(f"rebuild-repos failed with exit code {r.status_code}")
        return r


# ---------------------------------------------------------------------------
# Phase resolution
# ---------------------------------------------------------------------------

def resolve_phases(args: argparse.Namespace) -> frozenset[str] | None:
    """Return canonical phase set from args.

    Returns None to signal a legacy special mode (--pull-repos or --rebuild-repos)
    which is handled by dedicated code in main() before the cycle loop.
    """
    legacy_flags = (
        args.build_only, args.execute_only, args.build_transfer_verify,
        args.pull_repos, args.rebuild_repos,
    )
    legacy_count = sum(bool(f) for f in legacy_flags)
    has_phases = args.phases is not None

    if legacy_count > 1:
        sys.exit(
            "ERROR: use at most one of --build-only, --execute-only, "
            "--build-transfer-verify, --pull-repos, --rebuild-repos."
        )
    if legacy_count >= 1 and has_phases:
        sys.exit(
            "ERROR: --phases cannot be combined with legacy mode flags "
            "(--build-only, --execute-only, --build-transfer-verify, "
            "--pull-repos, --rebuild-repos)."
        )

    if args.build_only:
        return frozenset(("build",))
    if args.execute_only:
        return frozenset(("execute", "verify"))
    if args.build_transfer_verify:
        return frozenset(("build", "transfer", "verify-run", "verify"))
    if args.pull_repos or args.rebuild_repos:
        return None

    if has_phases:
        requested = frozenset(p.strip() for p in args.phases.split(",") if p.strip())
        unknown = requested - VALID_PHASES
        if unknown:
            sys.exit(
                f"ERROR: unknown phase(s): {', '.join(sorted(unknown))}. "
                f"Valid phases: {', '.join(sorted(VALID_PHASES))}"
            )
        if "execute" in requested and "verify-run" in requested:
            sys.exit("ERROR: 'execute' and 'verify-run' are mutually exclusive in --phases.")
        return requested

    return DEFAULT_PHASES


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
    p.add_argument(
        "--build-transfer-verify",
        action="store_true",
        help="After transfer, run run-verify-only.ps1 instead of execute-mast-provisioning.ps1 "
        "(BUILD + TRANSFER + staged *-verify checks only).",
    )
    p.add_argument(
        "--pull-repos",
        action="store_true",
        help="Connect to unit and git pull (+ submodule update) all repos under "
        f"{CLONE_ROOT}. No build or transfer.",
    )
    p.add_argument(
        "--rebuild-repos",
        action="store_true",
        help="Build mast module, transfer, then force-reclone all repos via "
        "provide-mast.ps1 -Force (removes existing clones and re-clones fresh).",
    )
    p.add_argument(
        "--phases",
        default=None,
        metavar="PHASE[,PHASE...]",
        help=(
            "Comma-separated phases to run: build, transfer, execute, verify-run, verify, reset. "
            "Default: build,transfer,execute,verify,reset. "
            "Cannot be combined with --build-only, --execute-only, --build-transfer-verify, "
            "--pull-repos, or --rebuild-repos. "
            "Example: --phases transfer,execute,verify"
        ),
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
    modules = args.modules.split(",") if args.modules else ALL_MODULES
    creds = load_creds()
    if "unit" not in creds:
        sys.exit("ERROR: vault/creds.json must contain a 'unit' block.")
    if "smb" not in creds:
        sys.exit("ERROR: vault/creds.json must contain an 'smb' block (see creds.json.template).")

    phases = resolve_phases(args)

    LOG_ROOT.mkdir(parents=True, exist_ok=True)
    run_ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    run_log = LOG_ROOT / f"{run_ts}-run.log"
    run_started = time.monotonic()

    with log_to_file(run_log):
        log(f"Run log: {run_log}")
        log(f"Modules: {', '.join(modules)}")
        if phases is not None:
            log(f"Phases:  {', '.join(sorted(phases))}")
        log(f"Cycles:  {args.repeat}")
        log(f"VM:      {args.vbox_vm}  (snapshot: {args.snapshot})")
        log(f"Unit WinRM target: {args.host_unit}")
        log(f"WinRM wait: {args.winrm_wait_seconds}s")

        cycle_results: list[bool] = []
        unit_session: winrm.Session | None = None

        # --- one-shot special modes: --pull-repos and --rebuild-repos ---
        if args.pull_repos or args.rebuild_repos:
            try:
                with timed("WAIT FOR WINRM"):
                    wait_for_winrm(args.host_unit, creds["unit"], timeout=args.winrm_wait_seconds)
                unit_session = winrm_session(args.host_unit, creds["unit"])
                run_id = "run-" + datetime.now().strftime("%Y%m%d-%H%M%S")
                log_dir = setup_log_dir(1)

                if args.pull_repos:
                    phase_clear_unit_logs(unit_session)
                    phase_pull_repos(unit_session)
                    phase_start_mast_unit(unit_session)
                    phase_wait_for_unit_health(args.host_unit)
                    results = phase_verify(unit_session, modules, 0)
                    (log_dir / "results.json").write_text(json.dumps(results, indent=2))
                    passed = print_results(results, 1)
                    cycle_results.append(passed)
                    if not passed:
                        _fetch_diagnostics(unit_session)
                else:  # rebuild_repos
                    phase_build(args.hostname, ["mast"])
                    unit_stage = phase_transfer(
                        unit_session, args.hostname, run_id,
                        creds["smb"]["user"], creds["smb"]["pass"],
                    )
                    phase_clear_unit_logs(unit_session)
                    phase_run_rebuild_repos(unit_session, unit_stage)
                    phase_wait_for_unit_health(args.host_unit)
                    results = phase_verify(unit_session, modules, 0)
                    (log_dir / "results.json").write_text(json.dumps(results, indent=2))
                    passed = print_results(results, 1)
                    cycle_results.append(passed)
                    if not passed:
                        _fetch_diagnostics(unit_session)
            finally:
                _dispose_winrm_session(unit_session)

            log(
                f"[TIMING] Total run (run-prov-test.py): "
                f"{_format_elapsed(time.monotonic() - run_started)}"
            )
            total = len(cycle_results)
            passed_count = sum(cycle_results)
            log(f"\n{'='*60}")
            log(f"SUMMARY: {passed_count}/{total} cycles passed")
            log(f"Run log saved to: {run_log}")
            log(f"{'='*60}")
            sys.exit(0 if passed_count == total else 1)

        # --- standard phase-based cycle loop ---
        assert phases is not None  # guaranteed by resolve_phases when not pull/rebuild-repos
        built = False
        try:
            for cycle in range(1, args.repeat + 1):
                log(f"\n{'='*60}")
                log(f"CYCLE {cycle}/{args.repeat}")
                log(f"{'='*60}")
                log_dir = setup_log_dir(cycle)

                try:
                    run_id = "run-" + datetime.now().strftime("%Y%m%d-%H%M%S")

                    # BUILD
                    if "build" in phases and (not built or args.rebuild):
                        phase_build(args.hostname, modules)
                        built = True

                    # WINRM (needed for any non-build phase)
                    non_build = phases - {"build"}
                    if non_build and unit_session is None:
                        with timed("WAIT FOR WINRM"):
                            wait_for_winrm(args.host_unit, creds["unit"], timeout=args.winrm_wait_seconds)
                        unit_session = winrm_session(args.host_unit, creds["unit"])

                    if not non_build:
                        log("No non-build phases selected; stopping after build.")
                        break

                    # TRANSFER
                    unit_stage = ""
                    if "transfer" in phases:
                        unit_stage = phase_transfer(
                            unit_session,
                            args.hostname,
                            run_id,
                            creds["smb"]["user"],
                            creds["smb"]["pass"],
                        )
                    elif "execute" in phases or "verify-run" in phases:
                        # No transfer: probe for newest existing staging dir
                        r_probe = run_ps(
                            unit_session,
                            "Get-ChildItem 'C:\\mast-staging' -Directory -ErrorAction SilentlyContinue"
                            " | Sort-Object LastWriteTime -Descending"
                            " | Select-Object -First 1 -ExpandProperty FullName",
                            label="find-staging",
                            timeout_s=30,
                        )
                        unit_stage = r_probe.std_out.decode(errors="replace").strip()
                        if not unit_stage:
                            sys.exit(
                                "ERROR: transfer not in phases but no run directory found "
                                "under C:\\mast-staging on unit."
                            )
                        log(f"Using existing staging dir: {unit_stage}")

                    # EXECUTE or VERIFY-RUN
                    run_rc = 0
                    if "execute" in phases:
                        run_response = phase_execute(
                            unit_session, args.host_unit, creds["unit"], unit_stage,
                            modules=modules,
                            smb_user=creds["smb"]["user"],
                            smb_pass=creds["smb"]["pass"],
                        )
                        run_rc = run_response.status_code
                    elif "verify-run" in phases:
                        run_response = phase_run_verify_only(
                            unit_session, args.host_unit, creds["unit"], unit_stage,
                            modules=modules,
                        )
                        run_rc = run_response.status_code

                    # VERIFY
                    if "verify" in phases:
                        verify_only_mode = "verify-run" in phases and "execute" not in phases
                        results = phase_verify(
                            unit_session, modules, run_rc, verify_only=verify_only_mode,
                        )
                        (log_dir / "results.json").write_text(json.dumps(results, indent=2))
                        passed = print_results(results, cycle)
                        cycle_results.append(passed)
                        if not passed:
                            _fetch_diagnostics(unit_session)
                    else:
                        cycle_results.append(True)

                except Exception as exc:
                    log(f"\nCycle {cycle} ERROR: {exc}")
                    cycle_results.append(False)
                    if unit_session is not None:
                        try:
                            _fetch_execute_log_tail(unit_session)
                            _fetch_diagnostics(unit_session)
                        except Exception:
                            pass

                if cycle < args.repeat and not args.no_reset and "reset" in phases:
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

        if "verify" in phases:
            total = len(cycle_results)
            passed_count = sum(cycle_results)
            log(f"\n{'='*60}")
            log(f"SUMMARY: {passed_count}/{total} cycles passed")
            log(f"Run log saved to: {run_log}")
            log(f"{'='*60}")
            sys.exit(0 if passed_count == total else 1)


if __name__ == "__main__":
    main()
