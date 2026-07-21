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
        --host-unit mastw ^
        --hostname  mastw ^
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
        --host-unit mast-wis-01 --hostname mast-wis-01 ^
        --modules stage ^
        --phases build,transfer,execute,verify ^
        --no-reset

Re-run execute + verify only (reuse last transfer, no rebuild):
    python MAST_provisioning\\vm\\run-prov-test.py ^
        --host-unit mast-wis-01 --hostname mast-wis-01 ^
        --modules stage ^
        --phases execute,verify

Verify current unit state without running anything:
    python MAST_provisioning\\vm\\run-prov-test.py ^
        --host-unit mast-wis-01 --phases verify

Credentials read from vault/creds.json (gitignored):
    {
        "unit": {"user": ".\\\\mast", "pass": "..."},
        "smb":  {"user": "mast-transfer", "pass": "..."}
    }

Dependencies:
    pip install paramiko
"""

from __future__ import annotations

import argparse
import base64
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
    import paramiko  # type: ignore[import]  # noqa: F401 -- SSH transport (transport.SshSession)
except ImportError:
    sys.exit(
        "ERROR: paramiko is required for the SSH transport.\n"
        "Install it with:  pip install paramiko\n"
        "Then re-run this script."
    )

# Force stdout/stderr to UTF-8 with safe replacement. The default Windows
# console codepage (often cp1252) chokes on characters like U+FFFD (the
# replace-char emitted by .decode(errors="replace") for invalid bytes),
# which has happened during long pip-install spew that contained ANSI
# screen-clear escapes. A single print raise crashed the streaming log
# poller mid-run, leaving the operator blind for the rest of the cycle.
# Reconfiguring to UTF-8 with errors="replace" makes the poller resilient
# to whatever the unit emits.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
except (AttributeError, OSError):
    pass

import vm_lib
from vm_lib import (
    VAULT_CREDS,
    VBOXMANAGE,
    WINRM_BOOT_TIMEOUT_S,
    WINRM_CALL_TIMEOUT_S,
    WINRM_PORT,
    _dispose_winrm_session,
    _minify_ps,
    _ps_escape,
    check_rc,
    load_creds,
    reset_to_clean_snapshot,
    run_ps,
    ssh_session,
    unit_reset_to_snapshot,
    unit_start,
    unit_stop,
    vbox,
    vm_state,
    wait_for_ssh,
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
REPO_ROOT = Path(__file__).parent.parent
LOG_ROOT = Path(r"C:\MAST\logs\dev")

# Hostname of the provisioning server (this machine) as the unit will address it for SMB.
PROV_SERVER = os.environ.get("COMPUTERNAME") or socket.gethostname()

WINRM_TIMEOUT_S = 90 * 60
EXECUTE_POLL_INTERVAL_S = 20
VERIFY_ONLY_TIMEOUT_S = 30 * 60

EXPECTED_PYTHON = "C:\\Python312\\python.exe"
EXPECTED_REPOS_ROOT = "C:\\MAST\\repos"
CLONE_ROOT = EXPECTED_REPOS_ROOT
PULL_REPOS_SCRIPT = REPO_ROOT / "server" / "providers" / "mast" / "pull-mast-repos.ps1"
MAST_LOGS_BASE = "C:\\MAST\\logs"
SMOKE_LOG_DIR = f"{MAST_LOGS_BASE}\\smoke"
VERIFY_LOG_DIR = f"{MAST_LOGS_BASE}\\verify"

def _discover_all_modules() -> list[str]:
    """Return module names in execution order by calling the PowerShell helper
    Get-AllProviderModules in server/lib/mast-modules.psm1.

    Why subprocess instead of a Python-side JSON walk: the same discovery is
    needed by build-mast.ps1 and check-and-provision.ps1 (both PowerShell),
    so the canonical reader lives there. Per CLAUDE.md's DRY rule, "the PS
    file is the source of truth; Python is the caller" -- having a parallel
    Python implementation that happens to agree today is exactly the seam
    where drift creeps in once the PS impl gains a feature (e.g. filtering
    disabled providers) the Python forgets to mirror.

    Cost: one ~300-500 ms powershell.exe spawn at script load, amortized
    over the rest of the run.
    """
    mast_modules_psm1 = REPO_ROOT / "server" / "lib" / "mast-modules.psm1"
    providers_root = REPO_ROOT / "server" / "providers"
    if not mast_modules_psm1.is_file():
        sys.exit(f"ERROR: mast-modules.psm1 not found at {mast_modules_psm1}")

    # One-liner: import the helper, run it, emit one name per line.
    # Note: -OutputFormat Text + the line-per-name pipe avoids any pywinrm/
    # XML formatting that ConvertTo-Json or default formatters would add.
    ps_cmd = (
        f"Import-Module '{mast_modules_psm1}' -Force -DisableNameChecking; "
        f"Get-AllProviderModules -ProvidersRoot '{providers_root}' "
        f"| ForEach-Object {{ $_ }}"
    )
    proc = subprocess.run(
        [
            "powershell.exe",
            "-NoProfile", "-NonInteractive",
            "-ExecutionPolicy", "Bypass",
            "-OutputFormat", "Text",
            "-Command", ps_cmd,
        ],
        text=True, capture_output=True,
    )
    if proc.returncode != 0:
        sys.exit(
            f"ERROR: Get-AllProviderModules failed (exit {proc.returncode}). "
            f"stderr: {proc.stderr.strip()}"
        )
    if proc.stderr.strip():
        # Get-AllProviderModules emits Write-Warning for malformed module.json.
        # Forward those so the operator sees them at run start.
        print(proc.stderr.rstrip(), file=sys.stderr)

    return [ln.strip() for ln in proc.stdout.splitlines() if ln.strip()]


_ALL_MODULES_CACHE: list[str] | None = None


def all_modules() -> list[str]:
    """Provider modules in execution order (cached).

    Computed lazily on first use rather than at import, so importing this script
    (e.g. from a unit test exercising resolve_phases) does NOT spawn PowerShell
    for discovery -- only an actual run touches it.
    """
    global _ALL_MODULES_CACHE
    if _ALL_MODULES_CACHE is None:
        mods = _discover_all_modules()
        if not mods:
            sys.exit(
                f"ERROR: no providers discovered under {REPO_ROOT / 'server' / 'providers'}. "
                "Check the repo layout."
            )
        _ALL_MODULES_CACHE = mods
    return _ALL_MODULES_CACHE

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


# Route vm_lib's heartbeat / stdout-passthrough logging through our tee-to-file logger.
vm_lib.log_fn = log
vm_lib.log_raw_fn = log_raw


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


# _minify_ps moved to vm_lib (shared, import-pure WinRM payload helper, paired
# with assert_inline_dispatchable / winrm_encoded_cmd_len); imported above.


# ---------------------------------------------------------------------------
# Unit log path helper
# ---------------------------------------------------------------------------

def _find_unit_log_path(session: Any, log_filename: str) -> str:
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
# VirtualBox control -- canonical helpers live in vm_lib (vbox, vm_state,
# unit_stop, unit_reset_to_snapshot, unit_start, reset_to_clean_snapshot).
# ---------------------------------------------------------------------------


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

    def _new_session(self) -> Any:
        # SSH-only: the poller streams the execute log over its own SSH session
        # (a second paramiko connection, parallel to the main execute channel).
        # This replaces the WinRM session whose Basic-auth reconnect storm locked
        # the account out mid-run ("credentials rejected by the server").
        return ssh_session(
            self._host, self._cred,
            connect_timeout_s=self._CALL_TIMEOUT_S,
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

def phase_build(hostname: str, modules: list[str], proxy_mode: str) -> None:
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
            "-AllowMissingNetFx3Sxs",
            "-ProxyMode", proxy_mode,
            # The dev VM has 8 GB RAM; the production 32 GB -t vm mount cannot
            # attach there (imdisk exit 3, ENOMEM). File-backed keeps D: and
            # the astrometry smoke solve exercisable in VM cycles.
            "-ImdiskMountType", "file",
        ]
        if sorted(modules) != sorted(all_modules()):
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
    unit: Any,
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
        # Dispatch the pull script by FILE, not inline. Once it carries the
        # cleanup + disk-check logic it exceeds the ~8 KB WinRM EncodedCommand
        # cmdline limit that inline (minified) dispatch is bounded by. Upload it
        # in small base64 chunks (each run_ps stays well under the limit), then
        # invoke it by path. (check-and-provision.ps1 already uses -FilePath.)
        script_text = pull_script.read_text(encoding="ascii")
        b64 = base64.b64encode(script_text.encode("utf-8")).decode("ascii")
        remote_ps = "C:\\mast-staging\\mast-pull-staging.ps1"
        remote_b64 = "C:\\mast-staging\\mast-pull-staging.b64"

        # Stage dir + truncate the b64 sink (one small call).
        run_ps(
            unit,
            "$d='C:\\mast-staging'; if(-not(Test-Path $d)){New-Item -ItemType Directory -Force -Path $d|Out-Null}; "
            f"Set-Content -LiteralPath '{remote_b64}' -Value '' -NoNewline -Encoding ascii",
            label="xfer-prep", timeout_s=60, echo=False,
        )
        # Append the base64 in chunks; base64 is quote/newline-free so each
        # single-quoted value is safe, and each call stays small.
        for i in range(0, len(b64), 1500):
            run_ps(
                unit,
                f"Add-Content -LiteralPath '{remote_b64}' -Value '{b64[i:i + 1500]}' -NoNewline -Encoding ascii",
                label="xfer-chunk", timeout_s=60, echo=False,
            )
        # Decode the b64 back to the .ps1 on the unit.
        run_ps(
            unit,
            f"[System.IO.File]::WriteAllBytes('{remote_ps}', [Convert]::FromBase64String((Get-Content -LiteralPath '{remote_b64}' -Raw)))",
            label="xfer-decode", timeout_s=60, echo=False,
        )

        # Run the uploaded script as a SCRIPTBLOCK built from its text, not as a
        # .ps1 file: invoking the file directly trips the unit's Restricted
        # ExecutionPolicy ("running scripts is disabled"), whereas a scriptblock
        # does not. This also keeps the invocation command tiny (the body lives
        # on the unit's disk, not on the command line).
        ps = (
            f"$sb = [scriptblock]::Create((Get-Content -LiteralPath '{remote_ps}' -Raw))\n"
            f"$r = & $sb"
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

        log(f"[transfer] mast-pull-staging.ps1 (file-dispatch) -ProvServer '{PROV_SERVER}' -UnitStage '{unit_stage}'")
        r = run_ps(unit, ps, label="transfer", timeout_s=60 * 60, echo=False)
        if r.status_code != 0:
            raise RuntimeError(f"Transfer failed (exit code: {r.status_code})")
        return unit_stage


def phase_execute(
    unit: Any,
    host_unit: str,
    unit_cred: dict[str, str],
    staging_path: str,
    modules: list[str] | None = None,
    smb_user: str = "",
    smb_pass: str = "",
) -> Any:
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
            if modules and sorted(modules) != sorted(all_modules()):
                execute_cmd += f" -Modules '{','.join(modules)}'"
            r = run_ps(unit, execute_cmd, label="execute", timeout_s=WINRM_TIMEOUT_S, step_timer=step_timer)
        finally:
            poller.stop()

        if r.status_code != 0:
            log(f"Execute exited with code {r.status_code} - fetching tail of execute log...")
            _fetch_execute_log_tail(unit)

        return r


def phase_run_verify_only(
    unit: Any,
    host_unit: str,
    unit_cred: dict[str, str],
    staging_path: str,
    modules: list[str] | None = None,
) -> Any:
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
            if modules and sorted(modules) != sorted(all_modules()):
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


def _fetch_session_log_tail(unit: Any, log_filename: str, lines: int = 40) -> None:
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


def _fetch_execute_log_tail(unit: Any, lines: int = 40) -> None:
    _fetch_session_log_tail(unit, "provisioning-execute.log", lines)


def _fetch_diagnostics(unit: Any) -> None:
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
    unit: Any,
    modules: list[str],
    run_rc: int,
    *,
    verify_only: bool = False,
    host: str = "",
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
            results["repos_root_checked"] = False
            results["unit_health_ok"] = True
            results["unit_health_detail"] = "(skipped in verify-only mode)"
            results["smoke"] = {}
            return results

        check_python = "python" in modules
        check_repos = "mast" in modules

        if check_python:
            r = run_ps(unit, f'& "{EXPECTED_PYTHON}" --version', label="python-check")
            results["python_ok"] = r.status_code == 0
            results["python_version"] = (
                r.std_out.decode(errors="replace").strip()
                or r.std_err.decode(errors="replace").strip()
            )
        else:
            results["python_ok"] = True
            results["python_version"] = "(not tested - python module not selected)"

        if check_repos:
            r = run_ps(unit, f'Test-Path "{EXPECTED_REPOS_ROOT}"', label="repos-root")
            results["repos_root_ok"] = "True" in r.std_out.decode(errors="replace")
            results["repos_root_checked"] = True
        else:
            results["repos_root_ok"] = True
            results["repos_root_checked"] = False

        if check_repos and host:
            url = f"http://{host}:{MAST_UNIT_PORT}{MAST_UNIT_STATUS_PATH}"
            log(f"[unit-health] GET {url}")
            try:
                with urllib.request.urlopen(url, timeout=10) as resp:
                    body = json.loads(resp.read().decode())
                if "api_version" not in body:
                    raise ValueError(f"missing api_version in response: {body}")
                if body.get("errors"):
                    raise ValueError(f"unit reported errors: {body['errors']}")
                results["unit_health_ok"] = True
                results["unit_health_detail"] = f"api_version={body.get('api_version')!r}"
            except Exception as e:
                results["unit_health_ok"] = False
                results["unit_health_detail"] = str(e)
        else:
            results["unit_health_ok"] = True
            results["unit_health_detail"] = "(not checked)"

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
    python_ver = results.get("python_version", "")
    if "(not tested" not in python_ver:
        log(
            f"  python check      : {'OK' if results['python_ok'] else 'FAIL'}"
            f" ({python_ver})"
        )
    if results.get("repos_root_checked", True):
        log(f"  repos root        : {'OK' if results['repos_root_ok'] else 'FAIL'}")
    unit_health_detail = results.get("unit_health_detail", "")
    if "(not checked)" not in unit_health_detail and "(skipped" not in unit_health_detail:
        log(
            f"  unit heartbeat    : {'OK' if results.get('unit_health_ok') else 'FAIL'}"
            f" ({unit_health_detail})"
        )
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
        and results.get("unit_health_ok", True)
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
) -> Any:
    with timed("RESET PHASE"):
        reset_to_clean_snapshot(
            vbox_vm, snapshot, host_unit, unit_cred,
            winrm_wait_s=winrm_wait_s,
        )
        return wait_for_ssh(host_unit, unit_cred, timeout=winrm_wait_s)


def phase_pull_repos(unit: Any) -> None:
    """Pull all repos (+ submodules) on the unit in-place. No build or transfer needed."""
    with timed("PULL-REPOS PHASE"):
        if not PULL_REPOS_SCRIPT.exists():
            raise FileNotFoundError(f"pull-mast-repos.ps1 not found: {PULL_REPOS_SCRIPT}")
        script_text = _minify_ps(PULL_REPOS_SCRIPT.read_text(encoding="ascii"))
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


def phase_clear_unit_logs(unit: Any) -> None:
    """Stop MAST_unit and delete its NSSM stdout/stderr logs so the next run starts clean."""
    with timed("CLEAR UNIT LOGS PHASE"):
        ps = (
            "Stop-Service -Name 'mast-unit' -Force -ErrorAction SilentlyContinue\n"
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


def phase_start_mast_unit(unit: Any) -> None:
    """Start the MAST_unit service after a pull or rebuild."""
    log("[start-mast-unit] Starting MAST_unit service...")
    r = run_ps(
        unit,
        "Start-Service -Name 'mast-unit' -ErrorAction SilentlyContinue; "
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



def phase_run_rebuild_repos(unit: Any, staging_path: str) -> Any:
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
        help="WinRM target for the unit: hostname (recommended, e.g. mast-wis-01) or IPv4 if DNS is unavailable",
    )
    p.add_argument("--hostname", default="mast-wis-01", help="Windows hostname for the unit (default: mast-wis-01)")
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
    p.add_argument(
        "--proxy-mode",
        choices=["weizmann", "direct"],
        default="weizmann",
        help=(
            "Proxy mode baked into the staged commands.json (default: weizmann). "
            "'weizmann' configures env vars, WinINet, WinHTTP, and cygwin setup.exe "
            "to route through bcproxy.weizmann.ac.il:8080 (required when the unit is "
            "inside the Weizmann campus network). 'direct' clears all proxy surfaces "
            "and forces cygwin setup.exe net-method=Direct (required when the unit "
            "cannot reach bcproxy -- e.g. provisioning from a home network or a "
            "satellite site without the Weizmann VPN). The choice is purely about "
            "the unit's current network reachability, not whether this is a dev or "
            "prod run -- a dev test from on-campus uses 'weizmann'; a prod cycle "
            "against an off-campus unit uses 'direct'."
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
    p.add_argument(
        "--winrm-call-timeout-s",
        type=int,
        default=None,
        metavar="N",
        help=(
            "Override the per-WinRM-call read/operation timeout (default from "
            "vm_lib.WINRM_CALL_TIMEOUT_S=%d). Bump this for scenarios whose "
            "execute phase routinely runs longer than the default."
        ) % WINRM_CALL_TIMEOUT_S,
    )
    return p.parse_args()


def main() -> None:
    args = parse_args()

    # --winrm-call-timeout-s overrides the overall script timeout enforced
    # by _run_with_heartbeat (via WINRM_TIMEOUT_S / timeout_s). It no longer
    # affects WSMan per-Receive timeouts: those are fixed at _WSMAN_OP/READ
    # in vm_lib.winrm_session(), short on purpose so pywinrm notices dead
    # sockets and shell-done within seconds. WINRM_CALL_TIMEOUT_S is kept
    # in sync only for callers that still read it as a ceiling.
    if args.winrm_call_timeout_s is not None:
        global WINRM_TIMEOUT_S
        vm_lib.WINRM_CALL_TIMEOUT_S = args.winrm_call_timeout_s
        WINRM_TIMEOUT_S = max(WINRM_TIMEOUT_S, args.winrm_call_timeout_s)

    modules = args.modules.split(",") if args.modules else all_modules()

    # Banner -- print the chosen proxy mode prominently before any work so it
    # is obvious in scrollback when triaging "why did setup.exe / pip / git
    # fail to reach the network." Banner is duplicated by build-mast.ps1 and
    # the proxy/astrometry-deps providers so it appears at every layer.
    _proxy_banner = (
        "*** WEIZMANN-PROXY MODE ***"
        if args.proxy_mode == "weizmann"
        else "*** NO-WEIZMANN-PROXY (DIRECT) MODE ***"
    )
    log("===================================================================")
    log(f"[run-prov-test] {_proxy_banner}")
    log(f"[run-prov-test] --proxy-mode {args.proxy_mode}")
    log("===================================================================")

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
        log(f"Unit SSH target: {args.host_unit}")
        log(f"SSH wait: {args.winrm_wait_seconds}s")

        cycle_results: list[bool] = []
        unit_session: Any | None = None

        # --- one-shot special modes: --pull-repos and --rebuild-repos ---
        if args.pull_repos or args.rebuild_repos:
            try:
                with timed("CONNECT UNIT"):
                    unit_session = wait_for_ssh(
                        args.host_unit, creds["unit"], timeout=args.winrm_wait_seconds
                    )
                run_id = "run-" + datetime.now().strftime("%Y%m%d-%H%M%S")
                log_dir = setup_log_dir(1)

                if args.pull_repos:
                    phase_clear_unit_logs(unit_session)
                    phase_pull_repos(unit_session)
                    phase_start_mast_unit(unit_session)
                    phase_wait_for_unit_health(args.host_unit)
                    results = phase_verify(unit_session, modules, 0, host=args.host_unit)
                    (log_dir / "results.json").write_text(json.dumps(results, indent=2))
                    passed = print_results(results, 1)
                    cycle_results.append(passed)
                    if not passed:
                        _fetch_diagnostics(unit_session)
                else:  # rebuild_repos
                    phase_build(args.hostname, ["mast"], args.proxy_mode)
                    unit_stage = phase_transfer(
                        unit_session, args.hostname, run_id,
                        creds["smb"]["user"], creds["smb"]["pass"],
                    )
                    phase_clear_unit_logs(unit_session)
                    phase_run_rebuild_repos(unit_session, unit_stage)
                    phase_wait_for_unit_health(args.host_unit)
                    results = phase_verify(unit_session, modules, 0, host=args.host_unit)
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
                        phase_build(args.hostname, modules, args.proxy_mode)
                        built = True

                    # CONNECT (needed for any non-build phase). Prefers WinRM,
                    # falls back to SSH if WinRM Basic is rejected (post-reboot
                    # Public-profile 401 regression).
                    non_build = phases - {"build"}
                    if non_build and unit_session is None:
                        with timed("CONNECT UNIT"):
                            unit_session = wait_for_ssh(
                                args.host_unit, creds["unit"], timeout=args.winrm_wait_seconds
                            )

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
                            host=args.host_unit,
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
