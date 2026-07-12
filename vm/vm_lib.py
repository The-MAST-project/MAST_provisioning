"""Compatibility shim for the vm/ test harness.

The WinRM/SSH transport layer that used to live here was lifted into the
production package ``server/prov/transport.py`` (single source of truth, see
DECISIONS.md 2026-07-12) so the shipped driver does not depend on this test
module. This file now re-exports that transport surface unchanged and keeps only
the VirtualBox helpers, which are test-only (the production driver never touches
a VM). Existing ``import vm_lib`` / ``from vm_lib import ...`` call sites in
run-prov-test.py and test-suite.py keep working verbatim.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

# Make <repo>/server importable so the lifted transport package resolves.
_SERVER_DIR = Path(__file__).resolve().parent.parent / "server"
if str(_SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(_SERVER_DIR))

# Re-export the full transport public API (see prov.transport.__all__) ...
from prov.transport import *  # noqa: E402,F401,F403
# ... plus the underscored helpers the vm/ scripts and tests reference directly.
from prov.transport import (  # noqa: E402,F401
    WINRM_BOOT_TIMEOUT_S,
    _candidate_users,
    _dispose_winrm_session,
    _log,
    _minify_ps,
    _ps_escape,
    _run_with_heartbeat,
    wait_for_winrm,
)

# ---------------------------------------------------------------------------
# VirtualBox VM state (test-only)
#
# Canonical helpers for power-state inspection, snapshot management, and the
# stop-restore-start-wait recovery sequence. Both run-prov-test.py and
# test-suite.py use these -- do not reimplement elsewhere.
# ---------------------------------------------------------------------------

# VirtualBox -- canonical path on Windows. Override by setting VBOXMANAGE_PATH
# in the environment if VirtualBox is installed elsewhere.
VBOXMANAGE = Path(
    os.environ.get("VBOXMANAGE_PATH")
    or r"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
)
VM_STOP_POLL_TIMEOUT_S = 30


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
