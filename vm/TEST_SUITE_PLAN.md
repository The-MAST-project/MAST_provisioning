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
- `vm/vm_lib.py` is the canonical home for shared WinRM/credentials helpers
  (`load_creds`, `winrm_session`, `wait_for_winrm`, `run_ps`, `_ps_escape`,
  `upload_file_b64`) and re-exports `REPO_ROOT` / `VAULT_CREDS`.
  `test-suite.py` must import from `vm_lib` rather than redefining these or
  reading `vault/creds.json` directly. See `vm/DEBUGGING.md`.

## New File

`MAST_provisioning/vm/test-suite.py`

No other files are created or modified in this initial implementation. A DECISIONS.md
entry is added after implementation.

## Scenario Registry

Eleven scenarios total; five ACTIVE, six STUB:

| Name                              | Status | Description |
|-----------------------------------|--------|-------------|
| `full-provision`                  | ACTIVE | All modules, full phase cycle, verify all smoke markers |
| `full-provision-verify-only`      | ACTIVE | build+transfer+verify-run+verify+reset (no installers) |
| `interrupted-inject-fail`         | ACTIVE | Inject bomb at order=65, expect non-zero, reset, clean re-run |
| `failure-recover-no-reset`        | ACTIVE | Inject sporadic bomb, attempt 1 fails, second attempt succeeds against the same partially-provisioned unit (no snapshot reset between attempts) |
| `idempotent-after-manifest-wipe`  | ACTIVE | Full provision, delete `C:\MAST\installed-manifest.json` on the unit, full provision again; both runs PASS and all smoke markers remain correct (per-module idempotency without relying on the UNIT_SKIP shortcut) |
| `interrupted-vbox-poweroff`       | STUB   | Abruptly poweroff VM mid-execute via VBoxManage |
| `interrupted-network-drop`        | STUB   | Disable VBox NIC during transfer phase |
| `idempotent-reprovision`          | STUB   | Two full provisions; second should be UNIT_SKIP (requires `check-and-provision.ps1` driver, not `run-prov-test.py`) |
| `upgrade`                         | STUB   | Provision N then N+1; verify delta-only modules re-ran |
| `rollback`                        | STUB   | Provision N+1 then rollback to N |
| `uninstall`                       | STUB   | Provision all, uninstall one, verify removal |

## File Structure (`vm/test-suite.py`)

```
[1]  Shebang + module docstring (ASCII only per CLAUDE.md)
[2]  Imports: argparse, json, subprocess, sys, time, dataclasses, datetime, pathlib, typing
     plus `vm_lib` for shared constants/helpers (VAULT_CREDS, load_creds)
[3]  Constants (import VAULT_CREDS from vm_lib; define test-suite-only constants here)
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

Reuse the canonical paths from `vm_lib` (single source of truth per
`MAST_provisioning/CLAUDE.md` DRY rules) and only define what is test-suite
specific locally:

```python
from vm_lib import REPO_ROOT, VAULT_CREDS, load_creds

RUN_PROV_TEST  = Path(__file__).parent / "run-prov-test.py"
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
- `vault/creds.json` is present and parseable -- call `vm_lib.load_creds()` and
  catch `RuntimeError` (raised if the file is missing) and `json.JSONDecodeError`
  (raised if the file is malformed). Do not re-implement the credentials read
  inline.
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

### failure-recover-no-reset: recovery without VM snapshot rollback

This scenario models the realistic field case: a provisioning attempt fails
partway through (transient network blip, prov-server hiccup, sporadic
unit-side script failure), the operator does NOT roll back the unit VM, and
simply re-runs provisioning against the same partially-provisioned host. The
second attempt must complete cleanly.

The injected failure is a **sporadic bomb**: a PS one-liner gated on a marker
file. First time the command is invoked on a given unit, it creates the
marker and exits 1. Any subsequent invocation finds the marker and exits 0.
This is more realistic than the deterministic `interrupted-inject-fail` bomb
because real-world transient failures rarely repeat on retry. Of the three
injection mechanisms considered (NIC drop, prov-server kill, sporadic unit
script failure) this one is chosen because it (a) is fully deterministic for
test repeatability, (b) requires no host-side teardown that could leak into
later scenarios, and (c) targets the same staging-payload injection point as
the existing inject-fail bomb, keeping the test driver simple.

Sporadic bomb entry fields (injected at `BOMB_ORDER = 65`, between
nssm-verify and nomachine):

```python
{
    "order":  BOMB_ORDER,
    "desc":   "[TEST SPORADIC BOMB] fails once per unit, then self-clears",
    "cmd":    (
        "powershell.exe -NoProfile -Command \""
        "$m = 'C:\\MAST\\state\\sporadic-bomb.marker'; "
        "if (Test-Path $m) { Write-Host '[SPORADIC] marker present, passing'; exit 0 } "
        "else { New-Item -ItemType Directory -Force -Path (Split-Path $m) | Out-Null; "
        "       New-Item -ItemType File -Force -Path $m | Out-Null; "
        "       Write-Host '[SPORADIC] first hit, failing'; exit 1 }\""
    ),
    "module": "test-sporadic-bomb"
}
```

#### Three sub-invocations (NO reset between B and C)

```
Sub-run A  --phases build                              (clean commands.json produced)
           -> _patch_commands_json_inject_sporadic_bomb(hostname)
Sub-run B  --phases transfer,execute,verify            (sporadic bomb fires, fails)
           -> expect rc != 0
                                                       (NO --phases reset here:
                                                        partial state is preserved)
Sub-run C  --phases transfer,execute,verify            (same payload re-executed;
                                                        bomb finds marker, passes)
           -> expect rc == 0
Sub-run D  --phases reset                              (restore post-prepare snapshot
                                                        to leave a clean unit for the
                                                        next scenario; the marker is
                                                        wiped by the snapshot restore)
```

Notes:

- Sub-runs B and C reuse the same staging payload -- no second build. The
  scenario specifically tests that re-running execute against an in-flight
  unit converges, not that a rebuild fixes things.
- Modules from order 10 through 61 will re-run during sub-run C. They must
  be idempotent (this is already an assumption of `idempotent-reprovision`,
  so the same property is under test here from a different angle).
- Sub-run D is mandatory: without the snapshot restore, the marker file
  would persist across scenarios and the *next* run of
  `failure-recover-no-reset` would incorrectly pass on its first attempt.

#### Outcome

Overall PASS if sub-run B returned non-zero AND sub-run C returned 0.
If sub-run B returns 0 unexpectedly (bomb not reached, or marker leaked from
a prior run), log a WARNING and mark the scenario as ERROR rather than PASS.

#### New helper required

`_patch_commands_json_inject_sporadic_bomb(hostname)` mirrors
`_patch_commands_json_inject_bomb(hostname)` but emits the marker-gated `cmd`
string above. Both helpers share the same read-sort-write boilerplate; if
both end up in `test-suite.py`, factor out a small
`_inject_commands_json_entry(hostname, entry)` shared core.

### idempotent-after-manifest-wipe: re-provision with a wiped state file

Background: a successful provisioning run causes
`execute-mast-provisioning.ps1` to write `C:\MAST\installed-manifest.json` on
the unit (see `client/execute-mast-provisioning.ps1` near line 232). The
server-side `check-and-provision.ps1` reads that file and short-circuits
re-provisioning with a `UNIT_SKIP` event when the build and installed payload
hashes match. The STUB `idempotent-reprovision` scenario exists to exercise
that SKIP path.

This scenario is the dual case: what happens when the manifest is *absent*
on a unit that has already been provisioned. That is what the operator faces
after a disk wipe of `C:\MAST\` state files, a manual deletion during
debugging, or a future driver that intentionally forces a full re-run. The
unit's installed payload is current, but the orchestrator does not know that
and re-runs every module. The whole test reduces to "do all
`provide-<module>.ps1` scripts converge cleanly when run against a host where
their target is already installed?"

This is a strictly stronger idempotency check than `idempotent-reprovision`:
that test confirms the SKIP shortcut works; this one confirms idempotency
holds even when the shortcut is bypassed.

#### Four sub-invocations

```
Sub-run A  --phases build,transfer,execute,verify      (first full provision)
           -> expect rc == 0
           -> assert C:\MAST\installed-manifest.json exists on the unit
Sub-run B  delete C:\MAST\installed-manifest.json      (via WinRM, see below)
           -> assert deletion succeeded
Sub-run C  --phases build,transfer,execute,verify      (second full provision)
           -> expect rc == 0
           -> all smoke markers identical to those from sub-run A
           -> assert C:\MAST\installed-manifest.json exists again (rewritten)
Sub-run D  --phases reset                              (restore snapshot)
```

Notes:

- Sub-run B does **not** invoke `run-prov-test.py`. It connects to the unit
  directly via `vm_lib.winrm_session(host_unit, creds["unit"])`, runs
  `Remove-Item -Force -ErrorAction Stop 'C:\MAST\installed-manifest.json'`
  via `vm_lib.run_ps`, and `vm_lib.check_rc`s the result. This is the one
  place test-suite needs vm_lib for direct unit access; everything else
  flows through the subprocess driver.
- The full smoke-marker set must match between sub-run A and sub-run C. The
  marker set comes from the verify phase's report; the scenario runner caches
  it after A, re-reads it after C, and asserts equality. Any diff fails the
  scenario.
- Sub-run C's build phase regenerates the staging payload deterministically,
  so the payload hash recorded in the *new* installed-manifest.json after C
  must equal the one written after A. Assert this as a final sanity check
  (catches accidental non-determinism in `build-mast.ps1`).
- Forward-compatibility: if test-suite is later retargeted to drive
  `check-and-provision.ps1`, this scenario's expected behavior is unchanged
  (manifest absent -> no skip -> full re-run). The STUB
  `idempotent-reprovision` would be the one that diverges between drivers.

#### Outcome

Overall PASS if A.rc == 0 AND C.rc == 0 AND smoke markers match AND payload
hashes match. Any mismatch fails the scenario with a detailed diff in the
suite-results.json `detail` field.

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
Scenario                          Status   Outcome  Duration
----------------------------------------------------------------------
full-provision                    ACTIVE   PASS     42.3m
full-provision-verify-only        ACTIVE   PASS     8.1m
interrupted-inject-fail           ACTIVE   PASS     58.7m
failure-recover-no-reset          ACTIVE   PASS     71.4m
idempotent-after-manifest-wipe    ACTIVE   PASS     83.9m
interrupted-vbox-poweroff         STUB     SKIP     0.0s
interrupted-network-drop          STUB     SKIP     0.0s
idempotent-reprovision            STUB     SKIP     0.0s
upgrade                           STUB     SKIP     0.0s
rollback                          STUB     SKIP     0.0s
uninstall                         STUB     SKIP     0.0s
----------------------------------------------------------------------
PASS=5  FAIL=0  SKIP=6  ERROR=0
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
python vm\test-suite.py --scenario full-provision --host-unit mast-wis-01 --hostname mast-wis-01
python vm\test-suite.py --all --host-unit mast-wis-01 --hostname mast-wis-01
python vm\test-suite.py --scenario interrupted-inject-fail --host-unit mast-wis-01 --hostname mast-wis-01 --modules nssm,nomachine
```

Flags:

| Flag | Default | Notes |
|------|---------|-------|
| `--list` / `--scenario NAME` / `--all` | (required, mutually exclusive) | |
| `--host-unit HOST` | (required for non-list) | WinRM target |
| `--hostname HOSTNAME` | `mast-wis-01` | Windows hostname for build (mirrors `run-prov-test.py` default) |
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
   - Should print all 11 scenarios; no errors; exit 0.

2. `python vm\test-suite.py --scenario full-provision --host-unit mast-wis-01 --hostname mast-wis-01`
   - All smoke markers present; suite exits 0.

3. `python vm\test-suite.py --scenario interrupted-inject-fail --host-unit mast-wis-01 --hostname mast-wis-01 --modules nssm,nomachine`
   - Faster scope: only nssm+nomachine (bomb order=65 sits between them).
   - Verify sub-run B exits non-zero, sub-run D exits 0; overall PASS.

4. `python vm\test-suite.py --scenario failure-recover-no-reset --host-unit mast-wis-01 --hostname mast-wis-01 --modules nssm,nomachine`
   - Same fast scope as inject-fail.
   - Verify sub-run B exits non-zero (sporadic bomb first hit fails),
     sub-run C exits 0 (marker present, all modules re-run successfully
     against the partially-provisioned unit), sub-run D resets the snapshot
     to wipe the marker.

5. `python vm\test-suite.py --scenario idempotent-after-manifest-wipe --host-unit mast-wis-01 --hostname mast-wis-01`
   - Run full module set (no --modules override) so manifest covers the
     real payload.
   - Verify sub-run A produces `C:\MAST\installed-manifest.json` on the
     unit; sub-run B deletes it via WinRM; sub-run C re-runs the full
     pipeline and rewrites the manifest with the same payload hash; smoke
     marker sets from A and C match exactly.

6. `python vm\test-suite.py --all --host-unit mast-wis-01 --hostname mast-wis-01`
   - ACTIVE scenarios run; STUBs report SKIP; overall exit 0 if actives pass.

## DECISIONS.md Entry (to add after implementation)

Title: "test-suite.py: named VM provisioning test scenarios"
Content: scenario registry (ACTIVE/STUB), four-sub-invocation design for interrupted-inject-fail,
ephemeral staging patch justification.
