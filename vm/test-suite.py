#!/usr/bin/env python3
"""Named provisioning test scenarios for the VirtualBox dev unit.

Thin driver on top of run-prov-test.py. Each scenario calls
run-prov-test.py as one or more subprocesses (--phases per sub-invocation)
and asserts on the resulting exit codes plus, where relevant, on unit-side
state read via vm_lib.

Usage:
    python vm\\test-suite.py --list
    python vm\\test-suite.py --scenario full-provision --host-unit mast-wis-01
    python vm\\test-suite.py --all          --host-unit mast-wis-01
    python vm\\test-suite.py --scenario failure-recover-no-reset \\
        --host-unit mast-wis-01 --modules nssm,nomachine

Use --list to see the full scenario registry. See the DECISIONS.md entry
"vm/ test infrastructure" for the design rationale.

ASCII only per MAST_provisioning/CLAUDE.md. No emojis, em-dashes, or smart
quotes anywhere in this file.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import threading
import time
from collections import deque
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

import vm_lib
from vm_lib import (
    REPO_ROOT,
    VAULT_CREDS,
    VBOXMANAGE,
    check_rc,
    dump_json_file,
    load_creds,
    load_json_file,
    parse_json_text,
    reset_to_clean_snapshot,
    run_ps,
    vbox_snapshot_exists,
    vm_state,
    wait_for_winrm,
    winrm_session,
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

RUN_PROV_TEST = Path(__file__).parent / "run-prov-test.py"
STAGING_ROOT = REPO_ROOT / "staging"
SUITE_LOG_ROOT = Path(r"C:\MAST\logs\dev\tests")

# Bomb sits between nssm-verify (61) and nomachine (70). See plan.
BOMB_ORDER = 65
BOMB_MODULE = "test-bomb"
SPORADIC_BOMB_MODULE = "test-sporadic-bomb"

# Per-scenario overrides for run-prov-test.py's --winrm-call-timeout-s flag.
# Empty by default: the WinRM-exit hang that justified a 90-min override
# for full-provision is now fixed at the source via [Environment]::Exit()
# in client/execute-mast-provisioning.ps1 and client/run-verify-only.ps1.
# Add an entry here only if a scenario genuinely needs a longer transport
# timeout than vm_lib.WINRM_CALL_TIMEOUT_S.
SCENARIO_WINRM_CALL_TIMEOUT_S: dict[str, int] = {}

MANIFEST_REMOTE_PATH = r"C:\MAST\installed-manifest.json"
SPORADIC_BOMB_MARKER_REMOTE_PATH = r"C:\MAST\state\sporadic-bomb.marker"

# Outcomes (string-typed for direct JSON serialization)
PASS = "PASS"
FAIL = "FAIL"
SKIP = "SKIP"
ERROR = "ERROR"


# ---------------------------------------------------------------------------
# Dataclasses
# ---------------------------------------------------------------------------

@dataclass
class Scenario:
    name: str
    description: str
    phases: str       # comma-separated phases passed as --phases to run-prov-test.py
    modules: str      # "" = all (no --modules flag); "m1,m2" to filter
    repeat: int       # --repeat N
    expected_rc: int  # 0 = expect success
    status: str       # "ACTIVE" or "STUB"


@dataclass
class ScenarioResult:
    name: str
    status: str       # "ACTIVE" or "STUB"
    outcome: str      # "PASS" / "FAIL" / "SKIP" / "ERROR"
    duration_s: float
    detail: str = ""
    sub_runs: list[dict] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Scenario registry
# ---------------------------------------------------------------------------

SCENARIOS: list[Scenario] = [
    Scenario(
        name="full-provision",
        description="All modules, full phase cycle, verify all smoke markers.",
        phases="build,transfer,execute,verify,reset",
        modules="",
        repeat=1,
        expected_rc=0,
        status="ACTIVE",
    ),
    # DISABLED 2026-05-17: the scenario runs verify-run against a freshly
    # restored post-prepare snapshot (no installers have run), so every
    # verify command fails -- either because the binary is missing or
    # because C:\MAST\logs\verify hasn't been created yet, producing a
    # cascade of "Out-File ... DirectoryNotFoundException" failures.
    # Re-enable once the scenario is rewritten to chain a successful
    # execute phase before verify-run (or run-verify-only.ps1 is taught
    # to pre-create the verify log dir).
    # Scenario(
    #     name="full-provision-verify-only",
    #     description="build+transfer+verify-run+verify+reset (no installers).",
    #     phases="build,transfer,verify-run,verify,reset",
    #     modules="",
    #     repeat=1,
    #     expected_rc=0,
    #     status="ACTIVE",
    # ),
    Scenario(
        name="interrupted-inject-fail",
        description=(
            "Inject deterministic bomb at order=65, expect non-zero on first "
            "attempt; after snapshot reset, clean re-run must pass."
        ),
        phases="",   # custom multi-sub-run flow; not used directly
        modules="",
        repeat=1,
        expected_rc=0,
        status="ACTIVE",
    ),
    Scenario(
        name="failure-recover-no-reset",
        description=(
            "Inject sporadic (marker-gated) bomb. Attempt 1 fails; second "
            "attempt against the same partially-provisioned unit succeeds. "
            "No snapshot reset between attempts."
        ),
        phases="",
        modules="",
        repeat=1,
        expected_rc=0,
        status="ACTIVE",
    ),
    Scenario(
        name="idempotent-after-manifest-wipe",
        description=(
            "Full provision; delete C:\\MAST\\installed-manifest.json on the "
            "unit; full provision again. Both runs PASS and the rewritten "
            "manifest has the same payload_hash."
        ),
        phases="",
        modules="",
        repeat=1,
        expected_rc=0,
        status="ACTIVE",
    ),
    Scenario(
        name="interrupted-vbox-poweroff",
        description="Abruptly poweroff the VM mid-execute via VBoxManage.",
        phases="",
        modules="",
        repeat=1,
        expected_rc=0,
        status="STUB",
    ),
    Scenario(
        name="interrupted-network-drop",
        description="Disable the VBox NIC during the transfer phase.",
        phases="",
        modules="",
        repeat=1,
        expected_rc=0,
        status="STUB",
    ),
    Scenario(
        name="idempotent-reprovision",
        description=(
            "Two full provisions; second should be UNIT_SKIP. Requires the "
            "check-and-provision.ps1 driver, not run-prov-test.py."
        ),
        phases="",
        modules="",
        repeat=1,
        expected_rc=0,
        status="STUB",
    ),
    Scenario(
        name="upgrade",
        description="Provision N then N+1; verify only delta modules re-ran.",
        phases="",
        modules="",
        repeat=1,
        expected_rc=0,
        status="STUB",
    ),
    Scenario(
        name="rollback",
        description="Provision N+1 then roll back to N.",
        phases="",
        modules="",
        repeat=1,
        expected_rc=0,
        status="STUB",
    ),
    Scenario(
        name="uninstall",
        description="Provision all, uninstall one module, verify removal.",
        phases="",
        modules="",
        repeat=1,
        expected_rc=0,
        status="STUB",
    ),
]

SCENARIOS_BY_NAME = {s.name: s for s in SCENARIOS}


# ---------------------------------------------------------------------------
# Prerequisites check
# ---------------------------------------------------------------------------

def check_prerequisites(vbox_vm: str, snapshot: str) -> list[str]:
    errors: list[str] = []
    # Credentials present and parseable. load_creds() raises RuntimeError if
    # the file is missing; JSONDecodeError if it is malformed.
    try:
        load_creds()
    except RuntimeError as e:
        errors.append(str(e))
    except json.JSONDecodeError as e:
        errors.append(f"vault/creds.json is not valid JSON: {e}")

    if not VBOXMANAGE.exists():
        errors.append(f"VBoxManage.exe not found at: {VBOXMANAGE}")
    if not RUN_PROV_TEST.exists():
        errors.append(f"run-prov-test.py not found at: {RUN_PROV_TEST}")
    if VBOXMANAGE.exists():
        # Catches a typo in --vbox-vm before we waste minutes on a bad reset.
        try:
            vm_state(vbox_vm)
        except subprocess.CalledProcessError:
            errors.append(
                f"VBox VM {vbox_vm!r} not found. "
                f"Use VBoxManage list vms to inspect."
            )
        if not vbox_snapshot_exists(vbox_vm, snapshot):
            errors.append(
                f"VBox snapshot {snapshot!r} not found on VM {vbox_vm!r}. "
                f"Use VBoxManage snapshot {vbox_vm} list --machinereadable to inspect."
            )
    return errors


# ---------------------------------------------------------------------------
# Subprocess driver
# ---------------------------------------------------------------------------

def _build_prov_args(
    scenario: Scenario,
    host_unit: str,
    hostname: str,
    vbox_vm: str,
    snapshot: str,
    modules_override: str | None,
    phases_override: str | None = None,
) -> list[str]:
    args: list[str] = [
        sys.executable, str(RUN_PROV_TEST),
        "--host-unit", host_unit,
        "--hostname", hostname,
        "--vbox-vm", vbox_vm,
        "--snapshot", snapshot,
    ]
    phases = phases_override if phases_override is not None else scenario.phases
    if phases:
        args += ["--phases", phases]
    modules = modules_override if modules_override is not None else scenario.modules
    if modules:
        args += ["--modules", modules]
    if scenario.repeat and scenario.repeat != 1:
        args += ["--repeat", str(scenario.repeat)]
    override = SCENARIO_WINRM_CALL_TIMEOUT_S.get(scenario.name)
    if override is not None:
        args += ["--winrm-call-timeout-s", str(override)]
    return args


def _replace_phases(args: list[str], new_phases: str) -> list[str]:
    out = list(args)
    if "--phases" in out:
        i = out.index("--phases")
        out[i + 1] = new_phases
    else:
        out += ["--phases", new_phases]
    return out


# Module-level run-context, populated by main() and read by runners/subprocess
# driver. Threading these through every runner signature would be noisier than
# the benefit; keep them here.
_RUN_CTX: dict = {
    "scenario_log_dir": None,    # Path
    "sub_idx": 0,                # incrementing counter for sub-run filename prefix
    "verbose": False,
    "tail_on_fail": 30,
    "heartbeat_s": 10.0,         # interval for the alive heartbeat line
}


_LABEL_SAFE_RE = re.compile(r"[^A-Za-z0-9._-]+")


def _safe_label(label: str) -> str:
    """Normalize a sub-run label into a filename fragment.

    'A: build (clean)' -> 'A-build-clean'
    """
    s = _LABEL_SAFE_RE.sub("-", label).strip("-")
    return s or "sub"


def _next_sub_log_path(label: str) -> Path | None:
    d: Path | None = _RUN_CTX.get("scenario_log_dir")
    if d is None:
        return None
    _RUN_CTX["sub_idx"] += 1
    n = _RUN_CTX["sub_idx"]
    return d / f"{n:02d}-{_safe_label(label)}.log"


def _print_tail(path: Path, n: int) -> None:
    if n <= 0 or path is None or not path.exists():
        return
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = deque(f, maxlen=n)
    except OSError as e:
        print(f"  [suite] could not read log for tail: {e}")
        return
    print(f"  --- tail (last {len(lines)} lines) of {path.name} ---")
    for line in lines:
        line = line.rstrip("\r\n")
        print(f"  {line}")
    print(f"  --- end tail ---")


def run_prov_subprocess(args: list[str], label: str) -> tuple[int, float]:
    """Call run-prov-test.py, capturing stdout+stderr to a per-sub-run log.

    Prints one '>' start line and one '<' end line. On non-zero exit, tails
    the captured log. With _RUN_CTX['verbose'] True, also echoes each
    captured line to stdout in real time.

    Returns (exit_code, elapsed_seconds).
    """
    log_path = _next_sub_log_path(label)
    verbose: bool = _RUN_CTX.get("verbose", False)
    tail_n: int = _RUN_CTX.get("tail_on_fail", 30)

    log_hint = f"log: {log_path.name}" if log_path else "log: <stdout only>"
    print(f"  > {label:<60} {log_hint}")
    t0 = time.monotonic()

    if log_path is None:
        # Fallback: no log dir set (shouldn't happen via main()); stream live.
        rc = subprocess.run(args, check=False).returncode
        elapsed = time.monotonic() - t0
        print(f"  < {label:<60} rc={rc}  {elapsed:.1f}s")
        return rc, elapsed

    rc = 1
    line_count = 0
    last_line_seen = ""
    heartbeat_s = float(_RUN_CTX.get("heartbeat_s", 10.0))
    stop_evt = threading.Event()
    try:
        with open(log_path, "w", encoding="utf-8", errors="replace",
                  newline="") as f:
            f.write(f"# argv: {' '.join(args[1:])}\n")
            f.flush()
            proc = subprocess.Popen(
                args,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=1,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
            assert proc.stdout is not None

            def _reader():
                nonlocal line_count, last_line_seen
                # readline() returns '' only on EOF; reliable line-at-a-time
                # without the iterator's read-ahead buffering.
                for line in iter(proc.stdout.readline, ""):
                    f.write(line)
                    f.flush()           # flush each line to disk so tail -f works
                    line_count += 1
                    stripped = line.rstrip("\r\n")
                    if stripped:
                        last_line_seen = stripped
                    if verbose:
                        sys.stdout.write(line)
                        sys.stdout.flush()
                stop_evt.set()

            reader = threading.Thread(target=_reader, daemon=True)
            reader.start()

            # Stdout heartbeat (suppressed in verbose, where the live stream
            # already shows progress).
            last_beat = time.monotonic()
            last_lines = 0
            while not stop_evt.wait(timeout=1.0):
                now = time.monotonic()
                if not verbose and (now - last_beat) >= heartbeat_s:
                    delta = line_count - last_lines
                    tail = last_line_seen[-110:] if last_line_seen else "(no output yet)"
                    print(f"    [running {now - t0:>5.0f}s "
                          f"lines={line_count} (+{delta}) -> {log_path.name}]")
                    print(f"      last: {tail}")
                    last_beat = now
                    last_lines = line_count

            reader.join()
            try:
                proc.stdout.close()
            except OSError:
                pass
            rc = proc.wait()
    except OSError as e:
        elapsed = time.monotonic() - t0
        print(f"  < {label:<60} ERROR  {elapsed:.1f}s  ({e})")
        return 2, elapsed

    elapsed = time.monotonic() - t0
    print(f"  < {label:<60} rc={rc}  {elapsed:.1f}s  lines={line_count}")
    if rc != 0:
        _print_tail(log_path, tail_n)
    return rc, elapsed


# ---------------------------------------------------------------------------
# commands.json injection
# ---------------------------------------------------------------------------

def _staging_commands_json(hostname: str) -> Path:
    return STAGING_ROOT / hostname / "01-provisioning" / "commands.json"


def _inject_commands_json_entry(hostname: str, entry: dict) -> Path:
    """Append an entry to the host's staged commands.json, re-sorted by order.

    CLAUDE.md warns against editing staging/ as a rule, because the build
    regenerates it. That convention is preserved here: this injection is
    explicitly ephemeral. The next build sub-invocation in a scenario
    overwrites commands.json from source, removing the entry.
    """
    path = _staging_commands_json(hostname)
    if not path.exists():
        raise FileNotFoundError(
            f"staged commands.json not found: {path}. Did the build sub-run succeed?"
        )
    data = load_json_file(path)
    if not isinstance(data, list):
        raise RuntimeError(f"commands.json is not a list: {path}")
    data = [e for e in data if e.get("module") != entry.get("module")]
    data.append(entry)
    data.sort(key=lambda e: int(e["order"]))
    dump_json_file(path, data)
    return path


def _patch_commands_json_inject_bomb(hostname: str) -> Path:
    entry = {
        "order":  BOMB_ORDER,
        "desc":   "[TEST BOMB] synthetic deterministic failure injected by test-suite.py",
        "cmd":    "powershell.exe -NoProfile -Command \"Write-Host '[BOMB] synthetic failure'; exit 1\"",
        "module": BOMB_MODULE,
    }
    return _inject_commands_json_entry(hostname, entry)


def _patch_commands_json_inject_sporadic_bomb(hostname: str) -> Path:
    cmd = (
        "powershell.exe -NoProfile -Command \""
        "$m = 'C:\\MAST\\state\\sporadic-bomb.marker'; "
        "if (Test-Path $m) { Write-Host '[SPORADIC] marker present, passing'; exit 0 } "
        "else { New-Item -ItemType Directory -Force -Path (Split-Path $m) | Out-Null; "
        "       New-Item -ItemType File -Force -Path $m | Out-Null; "
        "       Write-Host '[SPORADIC] first hit, failing'; exit 1 }\""
    )
    entry = {
        "order":  BOMB_ORDER,
        "desc":   "[TEST SPORADIC BOMB] fails once per unit, then self-clears",
        "cmd":    cmd,
        "module": SPORADIC_BOMB_MODULE,
    }
    return _inject_commands_json_entry(hostname, entry)


# ---------------------------------------------------------------------------
# Unit-side state helpers (via vm_lib)
# ---------------------------------------------------------------------------

def _unit_read_installed_manifest(host_unit: str, creds: dict) -> dict | None:
    """Return the parsed installed-manifest.json from the unit, or None if missing."""
    s = winrm_session(host_unit, creds["unit"])
    ps = (
        f"$p = '{MANIFEST_REMOTE_PATH}'; "
        "if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Raw } "
        "else { '' }"
    )
    r = run_ps(s, ps, label="read-manifest", echo=False)
    check_rc(r, "read-manifest")
    text = (r.std_out or b"").decode(errors="replace").strip()
    if not text:
        return None
    try:
        return parse_json_text(text)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"installed-manifest.json on unit is not valid JSON: {e}")


def _unit_delete_installed_manifest(host_unit: str, creds: dict) -> None:
    s = winrm_session(host_unit, creds["unit"])
    ps = (
        f"$p = '{MANIFEST_REMOTE_PATH}'; "
        "if (Test-Path -LiteralPath $p) { "
        "    Remove-Item -LiteralPath $p -Force -ErrorAction Stop; "
        "    Write-Host '[suite] deleted installed-manifest.json' "
        "} else { Write-Host '[suite] installed-manifest.json not present (already gone)' }"
    )
    r = run_ps(s, ps, label="del-manifest")
    check_rc(r, "del-manifest")


# ---------------------------------------------------------------------------
# Scenario runners
# ---------------------------------------------------------------------------

def run_simple_scenario(
    scenario: Scenario,
    host_unit: str,
    hostname: str,
    vbox_vm: str,
    snapshot: str,
    modules_override: str | None,
) -> ScenarioResult:
    t0 = time.monotonic()
    args = _build_prov_args(scenario, host_unit, hostname, vbox_vm, snapshot, modules_override)
    rc, elapsed = run_prov_subprocess(args, f"{scenario.name} (full)")
    outcome = PASS if rc == scenario.expected_rc else FAIL
    detail = "" if outcome == PASS else f"rc={rc}, expected={scenario.expected_rc}"
    return ScenarioResult(
        name=scenario.name,
        status=scenario.status,
        outcome=outcome,
        duration_s=time.monotonic() - t0,
        detail=detail,
        sub_runs=[{"label": "full", "rc": rc, "duration_s": elapsed}],
    )


def run_interrupted_inject_fail(
    scenario: Scenario,
    host_unit: str,
    hostname: str,
    vbox_vm: str,
    snapshot: str,
    modules_override: str | None,
) -> ScenarioResult:
    t0 = time.monotonic()
    base = _build_prov_args(scenario, host_unit, hostname, vbox_vm, snapshot, modules_override)
    sub_runs: list[dict] = []

    rc_a, e_a = run_prov_subprocess(_replace_phases(base, "build"), "A: build (clean)")
    sub_runs.append({"label": "A:build", "rc": rc_a, "duration_s": e_a})
    if rc_a != 0:
        return ScenarioResult(scenario.name, scenario.status, ERROR,
                              time.monotonic() - t0,
                              f"sub-run A (build) failed: rc={rc_a}", sub_runs)

    _patch_commands_json_inject_bomb(hostname)

    rc_b, e_b = run_prov_subprocess(_replace_phases(base, "transfer,execute,verify"),
                                    "B: transfer,execute,verify (bomb present)")
    sub_runs.append({"label": "B:tev-bombed", "rc": rc_b, "duration_s": e_b})
    if rc_b == 0:
        sub_runs[-1]["warning"] = "bomb not reached: sub-run B unexpectedly succeeded"

    rc_c, e_c = run_prov_subprocess(_replace_phases(base, "reset"), "C: reset")
    sub_runs.append({"label": "C:reset", "rc": rc_c, "duration_s": e_c})

    rc_d, e_d = run_prov_subprocess(
        _replace_phases(base, "build,transfer,execute,verify,reset"),
        "D: clean rebuild + full cycle",
    )
    sub_runs.append({"label": "D:clean", "rc": rc_d, "duration_s": e_d})

    if rc_b != 0 and rc_d == 0:
        outcome, detail = PASS, ""
    elif rc_b == 0 and rc_d == 0:
        outcome, detail = ERROR, "bomb not reached in sub-run B (expected non-zero exit)"
    else:
        outcome, detail = FAIL, f"sub-run B rc={rc_b}, sub-run D rc={rc_d}"

    return ScenarioResult(
        scenario.name, scenario.status, outcome,
        time.monotonic() - t0, detail, sub_runs,
    )


def run_failure_recover_no_reset(
    scenario: Scenario,
    host_unit: str,
    hostname: str,
    vbox_vm: str,
    snapshot: str,
    modules_override: str | None,
) -> ScenarioResult:
    t0 = time.monotonic()
    base = _build_prov_args(scenario, host_unit, hostname, vbox_vm, snapshot, modules_override)
    sub_runs: list[dict] = []

    rc_a, e_a = run_prov_subprocess(_replace_phases(base, "build"), "A: build (clean)")
    sub_runs.append({"label": "A:build", "rc": rc_a, "duration_s": e_a})
    if rc_a != 0:
        return ScenarioResult(scenario.name, scenario.status, ERROR,
                              time.monotonic() - t0,
                              f"sub-run A (build) failed: rc={rc_a}", sub_runs)

    _patch_commands_json_inject_sporadic_bomb(hostname)

    rc_b, e_b = run_prov_subprocess(
        _replace_phases(base, "transfer,execute,verify"),
        "B: transfer,execute,verify (sporadic bomb, first hit)",
    )
    sub_runs.append({"label": "B:tev-first", "rc": rc_b, "duration_s": e_b})

    rc_c, e_c = run_prov_subprocess(
        _replace_phases(base, "transfer,execute,verify"),
        "C: transfer,execute,verify (sporadic bomb, second hit, no reset)",
    )
    sub_runs.append({"label": "C:tev-second", "rc": rc_c, "duration_s": e_c})

    rc_d, e_d = run_prov_subprocess(_replace_phases(base, "reset"), "D: reset (wipe marker)")
    sub_runs.append({"label": "D:reset", "rc": rc_d, "duration_s": e_d})

    if rc_b != 0 and rc_c == 0:
        outcome, detail = PASS, ""
    elif rc_b == 0:
        outcome = ERROR
        detail = ("sporadic bomb not reached in sub-run B (rc=0); marker may have "
                  "leaked from a previous run")
    else:
        outcome, detail = FAIL, f"sub-run B rc={rc_b}, sub-run C rc={rc_c}"

    return ScenarioResult(
        scenario.name, scenario.status, outcome,
        time.monotonic() - t0, detail, sub_runs,
    )


def run_idempotent_after_manifest_wipe(
    scenario: Scenario,
    host_unit: str,
    hostname: str,
    vbox_vm: str,
    snapshot: str,
    modules_override: str | None,
) -> ScenarioResult:
    t0 = time.monotonic()
    base = _build_prov_args(scenario, host_unit, hostname, vbox_vm, snapshot, modules_override)
    sub_runs: list[dict] = []

    creds = load_creds()
    # The unit is rebooted between sub-runs that include reset, but in this
    # scenario we don't reset until D, so we can talk to the unit between C
    # and D using the same creds.

    rc_a, e_a = run_prov_subprocess(
        _replace_phases(base, "build,transfer,execute,verify"),
        "A: full provision (first)",
    )
    sub_runs.append({"label": "A:full", "rc": rc_a, "duration_s": e_a})
    if rc_a != 0:
        return ScenarioResult(scenario.name, scenario.status, FAIL,
                              time.monotonic() - t0,
                              f"sub-run A failed: rc={rc_a}", sub_runs)

    # Read manifest after A.
    try:
        wait_for_winrm(host_unit, creds["unit"])
        manifest_a = _unit_read_installed_manifest(host_unit, creds)
    except Exception as e:
        return ScenarioResult(scenario.name, scenario.status, ERROR,
                              time.monotonic() - t0,
                              f"reading manifest after A failed: {e}", sub_runs)
    if manifest_a is None:
        return ScenarioResult(scenario.name, scenario.status, FAIL,
                              time.monotonic() - t0,
                              "installed-manifest.json missing after sub-run A",
                              sub_runs)
    hash_a = manifest_a.get("payload_hash")
    sub_runs.append({"label": "manifest-a", "payload_hash": hash_a})

    # Delete manifest on the unit.
    try:
        _unit_delete_installed_manifest(host_unit, creds)
    except Exception as e:
        return ScenarioResult(scenario.name, scenario.status, ERROR,
                              time.monotonic() - t0,
                              f"deleting manifest failed: {e}", sub_runs)
    sub_runs.append({"label": "B:delete-manifest", "rc": 0})

    rc_c, e_c = run_prov_subprocess(
        _replace_phases(base, "build,transfer,execute,verify"),
        "C: full provision (after manifest wipe)",
    )
    sub_runs.append({"label": "C:full", "rc": rc_c, "duration_s": e_c})
    if rc_c != 0:
        return ScenarioResult(scenario.name, scenario.status, FAIL,
                              time.monotonic() - t0,
                              f"sub-run C failed: rc={rc_c}", sub_runs)

    # Read manifest after C.
    try:
        manifest_c = _unit_read_installed_manifest(host_unit, creds)
    except Exception as e:
        return ScenarioResult(scenario.name, scenario.status, ERROR,
                              time.monotonic() - t0,
                              f"reading manifest after C failed: {e}", sub_runs)
    if manifest_c is None:
        return ScenarioResult(scenario.name, scenario.status, FAIL,
                              time.monotonic() - t0,
                              "installed-manifest.json missing after sub-run C",
                              sub_runs)
    hash_c = manifest_c.get("payload_hash")
    sub_runs.append({"label": "manifest-c", "payload_hash": hash_c})

    rc_d, e_d = run_prov_subprocess(_replace_phases(base, "reset"), "D: reset")
    sub_runs.append({"label": "D:reset", "rc": rc_d, "duration_s": e_d})

    if hash_a is None or hash_c is None:
        return ScenarioResult(scenario.name, scenario.status, FAIL,
                              time.monotonic() - t0,
                              f"payload_hash missing: a={hash_a!r}, c={hash_c!r}",
                              sub_runs)
    if hash_a != hash_c:
        return ScenarioResult(scenario.name, scenario.status, FAIL,
                              time.monotonic() - t0,
                              f"payload_hash mismatch: a={hash_a!r}, c={hash_c!r}",
                              sub_runs)

    return ScenarioResult(
        scenario.name, scenario.status, PASS,
        time.monotonic() - t0, "", sub_runs,
    )


def run_stub(
    scenario: Scenario,
    host_unit: str,
    hostname: str,
    vbox_vm: str,
    snapshot: str,
    modules_override: str | None,
) -> ScenarioResult:
    print(f"[suite] SKIP: '{scenario.name}' not yet implemented. {scenario.description}")
    return ScenarioResult(scenario.name, scenario.status, SKIP, 0.0, "stub", [])


SCENARIO_RUNNERS: dict[str, Callable[..., ScenarioResult]] = {
    "full-provision":                run_simple_scenario,
    # "full-provision-verify-only":    run_simple_scenario,  # see DISABLED note above
    "interrupted-inject-fail":       run_interrupted_inject_fail,
    "failure-recover-no-reset":      run_failure_recover_no_reset,
    "idempotent-after-manifest-wipe": run_idempotent_after_manifest_wipe,
}


def run_scenario(
    scenario: Scenario,
    host_unit: str,
    hostname: str,
    vbox_vm: str,
    snapshot: str,
    modules_override: str | None,
) -> ScenarioResult:
    if scenario.status == "STUB":
        return run_stub(scenario, host_unit, hostname, vbox_vm, snapshot, modules_override)
    runner = SCENARIO_RUNNERS.get(scenario.name)
    if runner is None:
        return ScenarioResult(
            scenario.name, scenario.status, ERROR, 0.0,
            f"no ACTIVE runner registered for scenario {scenario.name!r}", [],
        )
    try:
        return runner(scenario, host_unit, hostname, vbox_vm, snapshot, modules_override)
    except Exception as e:
        return ScenarioResult(
            scenario.name, scenario.status, ERROR, 0.0,
            f"unhandled exception: {type(e).__name__}: {e}", [],
        )


# ---------------------------------------------------------------------------
# Reporter
# ---------------------------------------------------------------------------

BANNER_WIDTH = 80


def _tally(results: list[ScenarioResult]) -> dict[str, int]:
    counts = {PASS: 0, FAIL: 0, SKIP: 0, ERROR: 0}
    for r in results:
        counts[r.outcome] = counts.get(r.outcome, 0) + 1
    return counts


def _wrap_indent(text: str, indent: str, width: int) -> list[str]:
    """Wrap `text` onto lines, each prefixed by `indent`, fitting within width."""
    words = text.split()
    out: list[str] = []
    cur = indent
    avail = width - len(indent)
    for w in words:
        if len(cur) - len(indent) == 0:
            cur += w
        elif len(cur) - len(indent) + 1 + len(w) <= avail:
            cur += " " + w
        else:
            out.append(cur)
            cur = indent + w
    if cur.strip():
        out.append(cur)
    return out


def _print_scenario_banner(
    idx: int,
    total: int,
    scenario: Scenario,
    scenario_log_dir: Path,
    results_so_far: list[ScenarioResult],
) -> None:
    bar = "=" * BANNER_WIDTH
    counts = _tally(results_so_far)
    remaining = total - idx
    progress = (
        f"Progress: PASS={counts[PASS]} FAIL={counts[FAIL]} "
        f"SKIP={counts[SKIP]} ERROR={counts[ERROR]}  |  {remaining} remaining"
    )
    print()
    print(bar)
    print(f"[{idx}/{total}] Scenario: {scenario.name}  ({scenario.status})")
    for line in _wrap_indent(scenario.description, "      ", BANNER_WIDTH):
        print(line)
    print(f"      {progress}")
    print(f"      Log dir: {scenario_log_dir}")
    print(bar)


def _print_scenario_footer(idx: int, total: int, result: ScenarioResult) -> None:
    dash = "-" * BANNER_WIDTH
    dur = _fmt_duration(result.duration_s)
    tail = f": {result.detail}" if result.detail else ""
    print(dash)
    print(f"[{idx}/{total}] {result.name}: {result.outcome}{tail}  in {dur}")
    print(dash)


def _fmt_duration(seconds: float) -> str:
    if seconds < 1.0:
        return f"{seconds:.1f}s"
    if seconds < 60:
        return f"{seconds:.1f}s"
    return f"{seconds / 60.0:.1f}m"


def print_summary_table(results: list[ScenarioResult]) -> None:
    name_w = max(len("Scenario"), max((len(r.name) for r in results), default=8))
    print()
    print("=" * 78)
    print("SUITE RESULTS")
    print("=" * 78)
    print(f"{'Scenario':<{name_w}}  {'Status':<7} {'Outcome':<7} {'Duration':>9}")
    print("-" * 78)
    counts = {PASS: 0, FAIL: 0, SKIP: 0, ERROR: 0}
    for r in results:
        counts[r.outcome] = counts.get(r.outcome, 0) + 1
        print(f"{r.name:<{name_w}}  {r.status:<7} {r.outcome:<7} {_fmt_duration(r.duration_s):>9}")
        if r.detail:
            print(f"{'':<{name_w}}    detail: {r.detail}")
    print("-" * 78)
    print(f"PASS={counts[PASS]}  FAIL={counts[FAIL]}  SKIP={counts[SKIP]}  ERROR={counts[ERROR]}")


def write_suite_results_json(results: list[ScenarioResult], suite_log_dir: Path) -> Path:
    suite_log_dir.mkdir(parents=True, exist_ok=True)
    out = suite_log_dir / "suite-results.json"
    payload = {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "results": [asdict(r) for r in results],
    }
    out.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return out


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _cli_list() -> int:
    print(f"{'Name':<34}  {'Status':<7}  Description")
    print("-" * 78)
    for s in SCENARIOS:
        print(f"{s.name:<34}  {s.status:<7}  {s.description}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(
        description="Named provisioning test scenarios. Use --list to see them all.",
    )
    sel = p.add_mutually_exclusive_group(required=True)
    sel.add_argument("--list", action="store_true", help="List all scenarios and exit.")
    sel.add_argument("--scenario", metavar="NAME", help="Run one scenario by name.")
    sel.add_argument("--all", action="store_true", help="Run every scenario.")

    p.add_argument("--host-unit", metavar="HOST",
                   help="WinRM target hostname or IPv4 of the unit (required unless --list).")
    p.add_argument("--hostname", default="mast-wis-01",
                   help="Windows hostname for build (default: mast-wis-01).")
    p.add_argument("--vbox-vm", default="mast-unit",
                   help="VirtualBox VM name (default: mast-unit).")
    p.add_argument("--snapshot", default="post-prepare",
                   help="Snapshot to restore between cycles (default: post-prepare).")
    p.add_argument("--modules", default=None,
                   help="Override module list for all scenarios (comma-separated).")
    p.add_argument("--skip-prereq-check", action="store_true",
                   help="Skip prerequisite checks (creds, VBoxManage, snapshot, run-prov-test.py).")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="Also echo each sub-run's captured output to stdout in real time.")
    p.add_argument("--tail-on-fail", type=int, default=30, metavar="N",
                   help="On sub-run non-zero exit, print last N lines of its log "
                        "(default: 30; set 0 to disable).")

    args = p.parse_args()

    if args.list:
        return _cli_list()

    if not args.host_unit:
        p.error("--host-unit is required unless --list")

    if args.scenario is not None:
        if args.scenario not in SCENARIOS_BY_NAME:
            p.error(f"unknown scenario: {args.scenario!r}. Use --list to see all.")
        targets = [SCENARIOS_BY_NAME[args.scenario]]
    else:
        targets = list(SCENARIOS)

    if not args.skip_prereq_check:
        errs = check_prerequisites(args.vbox_vm, args.snapshot)
        if errs:
            print("[suite] Prerequisite checks failed:")
            for e in errs:
                print(f"  - {e}")
            return 2

    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%SZ")
    suite_log_dir = SUITE_LOG_ROOT / stamp
    suite_log_dir.mkdir(parents=True, exist_ok=True)
    print(f"[suite] log dir: {suite_log_dir}")
    print(f"[suite] running {len(targets)} scenario(s); "
          f"verbose={args.verbose}, tail_on_fail={args.tail_on_fail}")

    _RUN_CTX["verbose"] = args.verbose
    _RUN_CTX["tail_on_fail"] = args.tail_on_fail

    creds = load_creds()

    total = len(targets)
    results: list[ScenarioResult] = []
    for idx, s in enumerate(targets, start=1):
        scenario_log_dir = suite_log_dir / s.name
        scenario_log_dir.mkdir(parents=True, exist_ok=True)
        _RUN_CTX["scenario_log_dir"] = scenario_log_dir
        _RUN_CTX["sub_idx"] = 0

        _print_scenario_banner(idx, total, s, scenario_log_dir, results)

        if s.status == "ACTIVE":
            print(f"[suite] pre-flight: resetting VM {args.vbox_vm!r} "
                  f"to snapshot {args.snapshot!r}  (-> preflight.log)")
            preflight_log = scenario_log_dir / "preflight.log"
            t0 = time.monotonic()
            saved_log_fn = vm_lib.log_fn
            saved_log_raw_fn = vm_lib.log_raw_fn
            try:
                pf = open(preflight_log, "w", encoding="utf-8",
                          errors="replace", newline="")
                try:
                    def _pf_log(msg: str, _f=pf) -> None:
                        ts = datetime.now(timezone.utc).strftime("%H:%M:%SZ")
                        line = f"[{ts}] {msg}\n"
                        _f.write(line)
                        _f.flush()
                        if args.verbose:
                            sys.stdout.write(line)
                            sys.stdout.flush()

                    def _pf_log_raw(text: str, _f=pf) -> None:
                        _f.write(text if text.endswith("\n") else text + "\n")
                        _f.flush()
                        if args.verbose:
                            sys.stdout.write(text)
                            if not text.endswith("\n"):
                                sys.stdout.write("\n")
                            sys.stdout.flush()

                    vm_lib.log_fn = _pf_log
                    vm_lib.log_raw_fn = _pf_log_raw
                    reset_to_clean_snapshot(
                        args.vbox_vm, args.snapshot, args.host_unit, creds["unit"],
                    )
                finally:
                    pf.close()
            except Exception as e:
                vm_lib.log_fn = saved_log_fn
                vm_lib.log_raw_fn = saved_log_raw_fn
                detail = f"pre-flight reset failed: {type(e).__name__}: {e}"
                print(f"[suite] {detail}  (see {preflight_log.name})")
                _print_tail(preflight_log, args.tail_on_fail)
                r = ScenarioResult(
                    name=s.name, status=s.status, outcome=ERROR,
                    duration_s=time.monotonic() - t0, detail=detail, sub_runs=[],
                )
                results.append(r)
                _print_scenario_footer(idx, total, r)
                continue
            else:
                vm_lib.log_fn = saved_log_fn
                vm_lib.log_raw_fn = saved_log_raw_fn
                print(f"[suite] pre-flight done in {time.monotonic() - t0:.1f}s")

        r = run_scenario(s, args.host_unit, args.hostname, args.vbox_vm,
                         args.snapshot, args.modules)
        results.append(r)
        _print_scenario_footer(idx, total, r)

    print_summary_table(results)
    out = write_suite_results_json(results, suite_log_dir)
    print(f"[suite] wrote {out}")

    # Exit 0 if no ACTIVE scenario failed or errored.
    bad = [r for r in results if r.status == "ACTIVE" and r.outcome not in (PASS, SKIP)]
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
