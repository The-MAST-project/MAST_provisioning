# VM Provisioning Test Suite Plan

## Context

The MAST project has a VirtualBox-based dev/test path (`vm/run-prov-test.py`) for
iterating on individual modules, but no named, repeatable test scenarios for validating
the full provision cycle. This plan adds `vm/test-suite.py`: a thin driver that defines
named scenarios, calls `run-prov-test.py` as a subprocess for each one, and reports
structured results. It also includes stubs for interrupted-provision variants and future
versioning tests (rollback, upgrade, uninstall).

## Verified Facts (from code inspection)

- `execute-mast-provisioning.ps1` does NOT stop on first failure. It runs all commands,
  then exits 1 if `failCount > 0`. A bomb module injected at order=65 will fail, but
  modules 70+ (nomachine, phd2, etc.) will still execute. The interrupted scenario
  therefore tests "non-zero exit from a run containing a failing module," not
  "execution halted mid-stream."
- `commands.json` field schema: `order` (int), `desc` (str), `cmd` (str), `module` (str).
- `run-prov-test.py` flags: `--host-unit`, `--hostname`, `--modules`, `--repeat`,
  `--phases`, `--vbox-vm`, `--snapshot`, `--rebuild`, `--no-reset`, `--winrm-wait-seconds`.
- Valid phases: `build`, `transfer`, `execute`, `verify-run`, `verify`, `reset`.

## New File

`MAST_provisioning/vm/test-suite.py`

No other files are created or modified in this initial implementation. A DECISIONS.md
entry is added after implementation.

## Scenario Registry

Nine scenarios total; three ACTIVE, six STUB:

| Name                         | Status | Description |
|------------------------------|--------|-------------|
| `full-provision`             | ACTIVE | All modules, full phase cycle, verify all smoke markers |
| `full-provision-verify-only` | ACTIVE | build+transfer+verify-run+verify+reset (no installers) |
| `interrupted-inject-fail`    | ACTIVE | Inject bomb at order=65, expect non-zero, reset, clean re-run |
| `interrupted-vbox-poweroff`  | STUB   | Abruptly poweroff VM mid-execute via VBoxManage |
| `interrupted-network-drop`   | STUB   | Disable VBox NIC during transfer phase |
| `idempotent-reprovision`     | STUB   | Two full provisions; second should be UNIT_SKIP |
| `upgrade`                    | STUB   | Provision N then N+1; verify delta-only modules re-ran |
| `rollback`                   | STUB   | Provision N+1 then rollback to N |
| `uninstall`                  | STUB   | Provision all, uninstall one, verify removal |

## File Structure (`vm/test-suite.py`)

```
[1]  Shebang + module docstring (ASCII only per CLAUDE.md)
[2]  Imports: argparse, json, subprocess, sys, time, dataclasses, datetime, pathlib, typing
[3]  Constants (mirror run-prov-test.py conventions)
[4]  Scenario dataclass
[5]  SCENARIOS list
[6]  Prerequisites check
[7]  Subprocess helpers: _build_prov_args(), _replace_phases(), run_prov_subprocess()
[8]  Bomb injector: _patch_commands_json_inject_bomb()
[9]  Scenario runners: run_simple_scenario(), run_interrupted_inject_fail(), run_stub()
[10] ScenarioResult dataclass + suite runner
[11] Reporter: print_summary_table(), write_suite_results_json()
[12] CLI parser + main()
```

## Key Implementation Details

### Constants

```python
REPO_ROOT      = Path(__file__).parent.parent
RUN_PROV_TEST  = Path(__file__).parent / "run-prov-test.py"
VAULT_CREDS    = REPO_ROOT / "vault" / "creds.json"
VBOXMANAGE     = Path(r"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe")
SUITE_LOG_ROOT = Path(r"C:\MAST\logs\dev\tests")
BOMB_ORDER     = 65   # between nssm-verify (order 61) and nomachine (order 70)
```

### Scenario dataclass

```python
@dataclass
class Scenario:
    name: str
    description: str
    phases: str       # comma-separated string passed as --phases to run-prov-test.py
    modules: str      # "" = all (no --modules flag); "m1,m2" to filter
    repeat: int       # --repeat N
    expected_rc: int  # 0 = expect success, nonzero = expect failure
    status: str       # "ACTIVE" or "STUB"
```

### Prerequisites check

Before any run, verify:
- `vault/creds.json` exists
- `VBoxManage.exe` exists at known path
- Named snapshot exists on VM (`VBoxManage snapshot <vm> list --machinereadable`)
- `run-prov-test.py` exists

Print all errors and exit if any fail.

### Subprocess driver

`run_prov_subprocess(args, label)` calls `subprocess.run()` WITHOUT `capture_output=True`
so run-prov-test.py output streams live to the console. Returns `(exit_code, elapsed_s)`.

`_build_prov_args(scenario, host_unit, hostname, vbox_vm, snapshot, modules_override)`
builds the full argv list. Appends `--modules` only when modules string is non-empty.

`_replace_phases(args, new_phases)` returns a copy of args with the `--phases` value
replaced (used to split the interrupted scenario into separate sub-invocations).

### Bomb injector

`_patch_commands_json_inject_bomb(hostname)` runs AFTER the build sub-invocation and
BEFORE transfer. Reads `REPO_ROOT/staging/<hostname>/01-provisioning/commands.json`,
appends bomb entry, re-sorts by order, writes back.

Bomb entry fields:
```python
{
    "order":  BOMB_ORDER,                    # 65
    "desc":   "[TEST BOMB] synthetic failure injected by test-suite.py",
    "cmd":    "powershell.exe -NoProfile -Command \"Write-Host '[BOMB] synthetic failure'; exit 1\"",
    "module": "test-bomb"
}
```

Note on CLAUDE.md convention: the convention "do not edit staging/" is intended to
prevent permanent source changes being lost on next build. This injection is explicitly
ephemeral - the next `build` sub-invocation regenerates commands.json from source. The
code has a comment explaining this.

### interrupted-inject-fail: four sub-invocations

```
Sub-run A  --phases build                               (produces clean commands.json)
           -> _patch_commands_json_inject_bomb(hostname) (host-side edit)
Sub-run B  --phases transfer,execute,verify             (bomb is now in payload)
           -> expect rc != 0
Sub-run C  --phases reset                               (restore post-prepare snapshot)
Sub-run D  --phases build,transfer,execute,verify,reset (clean build, no bomb)
           -> expect rc == 0
```

Overall PASS if sub-run B returned non-zero AND sub-run D returned 0.
If sub-run B returns 0 unexpectedly (bomb not reached), log a WARNING and continue.

### STUB runner

```python
def run_stub(scenario):
    print("[suite] SKIP: '" + scenario.name + "' not yet implemented. " + scenario.description)
    return False, 0.0
```

STUBs report outcome=SKIP, not FAIL, so they don't block CI.

### Summary table (console output)

```
======================================================================
SUITE RESULTS
======================================================================
Scenario                         Status   Outcome  Duration
----------------------------------------------------------------------
full-provision                   ACTIVE   PASS     42.3m
full-provision-verify-only       ACTIVE   PASS     8.1m
interrupted-inject-fail          ACTIVE   PASS     58.7m
interrupted-vbox-poweroff        STUB     SKIP     0.0s
interrupted-network-drop         STUB     SKIP     0.0s
idempotent-reprovision           STUB     SKIP     0.0s
upgrade                          STUB     SKIP     0.0s
rollback                         STUB     SKIP     0.0s
uninstall                        STUB     SKIP     0.0s
----------------------------------------------------------------------
PASS=3  FAIL=0  SKIP=6  ERROR=0
```

### JSON output

Written to `C:\MAST\logs\dev\tests\<YYYYMMDD-HHMMSS>\suite-results.json`:

```json
{
  "generated_at": "2026-05-15T10:30:00Z",
  "results": [
    {"name": "full-provision", "status": "ACTIVE", "outcome": "PASS",
     "duration_s": 2538.1, "detail": ""}
  ]
}
```

Exit code: 0 if all ACTIVE scenarios passed; 1 if any ACTIVE scenario is FAIL or ERROR.

### CLI

```
python vm\test-suite.py --list
python vm\test-suite.py --scenario full-provision --host-unit mast01 --hostname mast01
python vm\test-suite.py --all --host-unit mast01 --hostname mast01
python vm\test-suite.py --scenario interrupted-inject-fail --host-unit mast01 --hostname mast01 --modules nssm,nomachine
```

Flags:

| Flag | Default | Notes |
|------|---------|-------|
| `--list` / `--scenario NAME` / `--all` | (required, mutually exclusive) | |
| `--host-unit HOST` | (required for non-list) | WinRM target |
| `--hostname HOSTNAME` | `mast01` | Windows hostname for build |
| `--vbox-vm VM` | `mast-unit` | VirtualBox VM name |
| `--snapshot SNAP` | `post-prepare` | Snapshot to restore between cycles |
| `--modules M1,M2` | (scenario default) | Override module list for all scenarios |

## Module Order Reference

Order=65 for the bomb sits cleanly between existing entries:

| Order | Module         |
|-------|----------------|
| 60    | nssm           |
| 61    | nssm-verify    |
| 65    | (bomb here)    |
| 70    | nomachine      |
| 71    | nomachine-verify |

## Verification Steps

1. `python vm\test-suite.py --list`
   - Should print all 9 scenarios; no errors; exit 0.

2. `python vm\test-suite.py --scenario full-provision --host-unit mast01 --hostname mast01`
   - All smoke markers present; suite exits 0.

3. `python vm\test-suite.py --scenario interrupted-inject-fail --host-unit mast01 --hostname mast01 --modules nssm,nomachine`
   - Faster scope: only nssm+nomachine (bomb order=65 sits between them).
   - Verify sub-run B exits non-zero, sub-run D exits 0; overall PASS.

4. `python vm\test-suite.py --all --host-unit mast01 --hostname mast01`
   - ACTIVE scenarios run; STUBs report SKIP; overall exit 0 if actives pass.

## DECISIONS.md Entry (to add after implementation)

Title: "test-suite.py: named VM provisioning test scenarios"
Content: scenario registry (ACTIVE/STUB), four-sub-invocation design for interrupted-inject-fail,
ephemeral staging patch justification.
