# Tests

Two tiers, deliberately. The goal is to catch **logic/decision** bugs in fast,
mock-free unit tests, and reserve the slow VM runs for genuine **integration**.

## Tier 1 — pure-logic unit tests (fast, no mocking)

`test_*.py` here exercise pure functions: given inputs, assert the decision —
no WinRM/SSH/SMB/VBox, no live unit. This is cheap **only because the logic is
factored out of the I/O**. The wedge is `vm/vm_lib.py`, which is *import-pure*
(it touches nothing at import), so importing it in a test costs nothing.

Covered today (`test_vm_lib.py`):
- `winrm_encoded_cmd_len` / `assert_inline_dispatchable` — the inline-dispatch
  size limit. A script too big for `powershell -EncodedCommand` now fails **fast
  and locally** with an actionable message instead of a remote "The command line
  is too long". (This is the regression that motivated the tier.)
- `_ps_escape`, `_candidate_users` — quoting / local-account variants.

Run:
```
python -m pytest vm/tests/          # if pytest is installed
python vm/tests/test_vm_lib.py      # standalone, no dependency
```

### How to add more without churn
Don't mock the ecosystem to fake a provision — that's the trap. Instead:
1. If the bug is a **decision** (size check, `rc>=8 -> ERROR`, phase selection,
   skip-if-present, disk-fits?), factor that decision into a pure function that
   takes plain inputs (sizes, codes, paths) and returns a verdict, then test the
   function. Push the I/O (the `Get-PSDrive`, the `robocopy`) to the caller.
2. Keep such helpers in an import-pure module (`vm_lib.py` for Python). If logic
   lives in `run-prov-test.py`, note that it does work at import
   (`ALL_MODULES = _discover_all_modules()` spawns PowerShell), so prefer moving
   shared pure helpers into `vm_lib.py` rather than importing the script.

### PowerShell logic (Pester, same principle)
Live in `server/tests/*.Tests.ps1`, run with the Pester that ships with Windows
PowerShell 5.1 (3.x: `Should Be`, not 5.x `Should -Be`):
```
Invoke-Pester -Path server\tests\mast-pull-staging.Tests.ps1
```
Implemented (`mast-pull-staging.Tests.ps1`): the pull script's pure decisions
`Get-RobocopyOutcome` (rc>=8 -> ROBOCOPY_ERROR) and `Test-StagingFits` (payload +
margin fits the disk). The script is dot-sourced with no `-SrcUNC`; a guard
(`if (-not $SrcUNC) { return }`) skips the live net use / robocopy so only the
pure functions load — no SMB, no unit, no cmdlet mocking.

How it stays cheap: factor a decision into a named function, guard the script's
side-effecting body behind a "were we actually invoked?" check, then dot-source
and assert. Mock at most one cmdlet (`Test-Path`/`Get-PSDrive`) if a function
must probe — never the whole ecosystem.

Next candidate (not yet done): the provider **skip-if-present** decision is
currently inlined in phd2/planewave/zwo/vscode. Extracting it to one shared,
tested helper (a real DRY win) would let a single Pester test cover all four.

## Tier 2 — e2e integration (slow, real VM)

`vm/run-prov-test.py` and `vm/test-suite.py` drive an actual provision against
the VirtualBox unit. These are the only place that catches genuinely
environmental behavior unit tests *should not* fake — e.g. WinRM ExecutionPolicy
on file vs scriptblock dispatch, SMB pull, driver installs, post-reboot network
state. Keep integration assertions here; keep decision assertions in Tier 1.
