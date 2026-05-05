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
        [--utm-unit-vm "Windows IoT"]

Credentials are read from vault/utm-creds.json (gitignored):
    {
        "prov":  {"user": ".\\mast", "pass": "..."},
        "unit":  {"user": ".\\mast", "pass": "..."},
        "smb":   {"user": "macuser", "pass": "..."}
    }

The "smb" entry is the Mac user account used to authenticate the SMB share mount
(\\192.168.64.1\\shared-utm) on the provisioning server.

Dependencies:
    pip install pywinrm
"""

from __future__ import annotations

import argparse
import json
import shutil
import socket
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

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

MAC_SMB_HOST = "192.168.64.1"
PROV_SHARE_DRIVE = "Z:"
PROV_SHARE_UNC = f"\\\\{MAC_SMB_HOST}\\shared-utm"
PROV_REPO_PATH = f"{PROV_SHARE_DRIVE}\\mast-prov"  # Z:\mast-prov → ~/shared-utm/mast-prov
STAGING_LOCAL = f"{PROV_SHARE_DRIVE}\\staging"  # Z:\staging\ = MAST_provisioning/staging/

WINRM_PORT = 5985
WINRM_TIMEOUT_S = 90 * 60  # 90 min for full provisioning run
WINRM_BOOT_TIMEOUT_S = 3 * 60

EXPECTED_REPOS = ["MAST_unit", "MAST_common"]
EXPECTED_PYTHON = "C:\\Python312\\python.exe"
EXPECTED_REPOS_ROOT = "C:\\MAST\\repos"
SMOKE_LOG_DIR = "C:\\ProgramData\\MAST\\logs"

ALL_MODULES = [
    "ascom", "cygwin", "mast", "mongodb", "nomachine",
    "nssm", "phd2", "planewave", "python", "stage",
    "sysinternals", "vscode", "wireshark", "zwo",
]


# ---------------------------------------------------------------------------
# Helpers
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
        read_timeout_sec=WINRM_TIMEOUT_S + 30,
        operation_timeout_sec=WINRM_TIMEOUT_S,
    )


def run_ps(session: winrm.Session, script: str, *, label: str = "") -> winrm.Response:
    """Run a PowerShell script block and stream stdout/stderr."""
    tag = f"[{label}] " if label else ""
    print(f"{tag}>>> {script[:120].rstrip()}")
    r = session.run_ps(script)
    if r.std_out:
        print(r.std_out.decode(errors="replace").rstrip())
    if r.std_err:
        print("[stderr]", r.std_err.decode(errors="replace").rstrip())
    return r


def check_rc(r: winrm.Response, phase: str) -> None:
    if r.status_code != 0:
        raise RuntimeError(f"{phase} failed with exit code {r.status_code}")


def wait_for_winrm(host: str, cred: dict[str, str], timeout: int = WINRM_BOOT_TIMEOUT_S) -> None:
    print(f"Waiting for WinRM on {host} (up to {timeout}s)…")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, WINRM_PORT), timeout=5):
                pass
            s = winrm_session(host, cred)
            r = s.run_cmd("echo", ["ping"])
            if r.status_code == 0:
                print(f"WinRM on {host} is ready.")
                return
        except Exception:
            pass
        time.sleep(5)
    raise TimeoutError(f"WinRM on {host} did not become reachable within {timeout}s")


def utmctl(*args: str) -> subprocess.CompletedProcess[str]:
    cmd = [str(UTMCTL), *args]
    return subprocess.run(cmd, check=True, text=True, capture_output=True)


def utm_vm_id(vm_name: str) -> str:
    """Return the UUID for the named UTM VM."""
    result = utmctl("list")
    for line in result.stdout.splitlines():
        # output format: <uuid>: <name> [<state>]
        if vm_name.lower() in line.lower():
            return line.split(":")[0].strip()
    raise ValueError(
        f"UTM VM named '{vm_name}' not found.\n"
        f"Available VMs:\n{result.stdout}"
    )


def utm_stop(vm_name: str) -> None:
    vid = utm_vm_id(vm_name)
    print(f"Stopping UTM VM '{vm_name}' ({vid})…")
    utmctl("stop", vid)


def utm_start(vm_name: str) -> None:
    vid = utm_vm_id(vm_name)
    print(f"Starting UTM VM '{vm_name}' ({vid}) in disposable mode…")
    utmctl("start", "--disposable", vid)


def setup_log_dir(cycle: int) -> Path:
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    log_dir = LOG_ROOT / f"{ts}-cycle{cycle}"
    log_dir.mkdir(parents=True, exist_ok=True)
    return log_dir


# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------

def phase_build(
    prov: winrm.Session,
    hostname: str,
    modules: list[str],
    smb_cred: dict[str, str],
) -> None:
    print("\n=== BUILD PHASE ===")
    # Z: on the provisioning server is already MAST_provisioning via UTM shared folder.
    # No SMB mount needed; -Top points directly at Z:\.
    # Pass -Modules as a PowerShell array literal; omit if using all modules (let script default).
    if sorted(modules) == sorted(ALL_MODULES):
        modules_arg = ""
    else:
        arr = ",".join(f"'{m}'" for m in modules)
        modules_arg = f" -Modules @({arr})"
    build_cmd = (
        f"Set-ExecutionPolicy Bypass -Scope Process -Force; "
        f"& '{PROV_SHARE_DRIVE}\\build\\build-mast.ps1'"
        f" -Top '{PROV_SHARE_DRIVE}\\'"
        f" -HostName '{hostname}'"
        f"{modules_arg}"
    )
    r = run_ps(prov, build_cmd, label="build")
    check_rc(r, "BUILD")
    print("BUILD: OK")


def phase_transfer(
    prov: winrm.Session,
    unit: winrm.Session,
    hostname: str,
    unit_cred: dict[str, str],
    host_unit: str,
) -> None:
    print("\n=== TRANSFER PHASE ===")
    staging_src = f"{STAGING_LOCAL}\\{hostname}"

    # Open a PSSession from prov server to unit and use Copy-Item
    transfer_script = f"""
$sopts = New-PSSessionOption -SkipCACheck -SkipCNCheck
$cred = New-Object System.Management.Automation.PSCredential(
    "{unit_cred['user']}",
    (ConvertTo-SecureString "{unit_cred['pass']}" -AsPlainText -Force)
)
$s = New-PSSession -ComputerName {host_unit} -Port {WINRM_PORT} -Credential $cred -SessionOption $sopts
if (-not $s) {{ Write-Error "Failed to open PSSession to unit"; exit 1 }}

Invoke-Command -Session $s -ScriptBlock {{
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "C:\\mast-staging"
    New-Item -ItemType Directory -Force "C:\\mast-staging" | Out-Null
}}

Copy-Item -Path "{staging_src}\\*" -Destination "C:\\mast-staging" -ToSession $s -Recurse -Force
Remove-PSSession $s
Write-Host "Transfer complete."
"""
    r = run_ps(prov, transfer_script.strip(), label="transfer")
    check_rc(r, "TRANSFER")
    print("TRANSFER: OK")


def phase_execute(unit: winrm.Session) -> winrm.Response:
    print("\n=== EXECUTE PHASE ===")
    execute_cmd = (
        "powershell.exe -ExecutionPolicy Bypass -NonInteractive "
        "-File \"C:\\mast-staging\\execute-mast-provisioning.ps1\" "
        "-StagingPath \"C:\\mast-staging\""
    )
    r = run_ps(unit, execute_cmd, label="execute")
    return r


def phase_verify(unit: winrm.Session, modules: list[str], execute_rc: int) -> dict[str, Any]:
    print("\n=== VERIFY PHASE ===")
    results: dict[str, Any] = {}

    results["execute_exit_code"] = execute_rc
    results["execute_ok"] = execute_rc == 0

    r = run_ps(unit, f'& "{EXPECTED_PYTHON}" --version', label="python-check")
    results["python_ok"] = r.status_code == 0
    results["python_version"] = r.std_out.decode(errors="replace").strip()

    r = run_ps(unit, f'Test-Path "{EXPECTED_REPOS_ROOT}"', label="repos-root")
    results["repos_root_ok"] = "True" in r.std_out.decode(errors="replace")

    smoke_checks: dict[str, bool] = {}
    for mod in modules:
        smoke_path = f"{SMOKE_LOG_DIR}\\{mod}-smoke.txt"
        r = run_ps(unit, f'(Get-Content "{smoke_path}" -ErrorAction SilentlyContinue) -eq "success"')
        smoke_checks[mod] = "True" in r.std_out.decode(errors="replace")
    results["smoke"] = smoke_checks

    return results


def print_results(results: dict[str, Any], cycle: int) -> bool:
    print(f"\n--- Cycle {cycle} Results ---")
    print(f"  execute exit code : {results['execute_exit_code']}")
    print(f"  python check      : {'OK' if results['python_ok'] else 'FAIL'} ({results.get('python_version', '')})")
    print(f"  repos root        : {'OK' if results['repos_root_ok'] else 'FAIL'}")
    print("  smoke tests:")
    smoke = results.get("smoke", {})
    for mod, passed in smoke.items():
        print(f"    {mod:<20} {'OK' if passed else 'FAIL'}")

    passed = (
        results["execute_ok"]
        and results["python_ok"]
        and results["repos_root_ok"]
        and all(smoke.values())
    )
    print(f"\n  Cycle {cycle}: {'PASS' if passed else 'FAIL'}")
    return passed


def phase_reset(utm_unit_vm: str, host_unit: str, unit_cred: dict[str, str]) -> winrm.Session:
    print("\n=== RESET PHASE ===")
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
    p.add_argument("--rebuild", action="store_true", help="Re-run build phase on every cycle (default: build once)")
    p.add_argument("--build-only", action="store_true", help="Only run the build phase; do not execute on unit")
    p.add_argument("--utm-unit-vm", default="mast-unit", help="UTM VM name for the IoT unit (default: 'mast-unit')")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    modules = args.modules.split(",") if args.modules else ALL_MODULES
    creds = load_creds()

    prov_session = winrm_session(args.host_prov, creds["prov"])
    unit_session = winrm_session(args.host_unit, creds["unit"])

    cycle_results: list[bool] = []
    built = False

    for cycle in range(1, args.repeat + 1):
        print(f"\n{'='*60}")
        print(f"CYCLE {cycle}/{args.repeat}")
        print(f"{'='*60}")
        log_dir = setup_log_dir(cycle)

        try:
            if not built or args.rebuild:
                phase_build(prov_session, args.hostname, modules, creds["smb"])
                built = True

            if args.build_only:
                print("--build-only specified; stopping after build.")
                break

            phase_transfer(prov_session, unit_session, args.hostname, creds["unit"], args.host_unit)

            execute_response = phase_execute(unit_session)

            results = phase_verify(unit_session, modules, execute_response.status_code)

            # Save results JSON for post-mortem
            (log_dir / "results.json").write_text(json.dumps(results, indent=2))

            passed = print_results(results, cycle)
            cycle_results.append(passed)

        except Exception as exc:
            print(f"\nCycle {cycle} ERROR: {exc}")
            cycle_results.append(False)

        if cycle < args.repeat:
            unit_session = phase_reset(args.utm_unit_vm, args.host_unit, creds["unit"])

    if not args.build_only:
        total = len(cycle_results)
        passed_count = sum(cycle_results)
        print(f"\n{'='*60}")
        print(f"SUMMARY: {passed_count}/{total} cycles passed")
        print(f"{'='*60}")
        sys.exit(0 if passed_count == total else 1)


if __name__ == "__main__":
    main()
