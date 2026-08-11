---
decided: 2026-08-11
status: accepted
issue: MAST_provisioning#65
areas:
  - docs-process
  - reproducibility
---

# CI is three jobs, Pester is pinned, and lint lands green

**Why:** this repo had no CI at all. Nothing ran its 377 pytest cases or its 89 Pester assertions automatically, which meant the guard tests written for #38, #51, #63 and #70 — whose entire purpose is to catch a regression nobody would otherwise notice — only ran when someone remembered to.

**What:** `.github/workflows/ci.yml`, following the `MAST_common` / `MAST_unit` house style (two independent jobs, blocking lint, `ruff format --check` before `ruff check`, `concurrency` with `cancel-in-progress`, `checkout@v7`, `setup-python@v7`, Python 3.12, `-q -ra`) with three departures this repo forces.

**1. A third job, because there are two test languages.** `pester` runs the 10 PowerShell suites on `windows-latest`, separate from `test` so a red lint cannot hide which language broke.

**2. Pester is pinned to 3.4.0, explicitly.** The suites are Pester 3 throughout — 112 `Should Be`, 9 `Should Throw`, 89 `It` — and 3.4.0 is what the units themselves carry. `windows-latest` ships Pester 5.x preinstalled *alongside* 3.4.0, and a bare `Import-Module Pester` picks 5.x, where every one of those 112 assertions is a syntax error. `shell: powershell` (5.1), not `pwsh` (7.x, no bundled Pester 3).

Two vacuous-pass traps closed in the same step: `Invoke-Pester` 3.x does not set a failing exit code, so the job reads `-PassThru`'s `FailedCount` itself; and a `PassedCount` of zero is treated as failure, because "the suites were not discovered" otherwise looks identical to success.

**3. pytest runs from the repo root.** Not `server/prov/tests`, or `vm/tests` is never collected — 6 of the 377 cases. And the job installs `server/requirements.txt` as well as `requirements-dev.txt`, because a missing `paramiko` does not fail a test: `vm/run-prov-test.py` imports it at module level and collection dies with `INTERNALERROR`, reporting zero tests.

**Lint lands green, and that is the substantive choice.** Adopting the fleet `ruff.toml` surfaced 195 findings and 27 unformatted files; all were cleared before CI landed, in five reviewable commits (config, formatter, safe fixes, mechanical families, judgement). Both siblings deliberately landed red — 202 and 269 findings — as visible debt.

The reason for diverging is this repo's own recent history: #55, #67, #68 and #69 are all cases where a permanently-failing signal was worth nothing, because it stopped being read and then hid the next real regression. A red lint check is the same defect in the same shape. The siblings' choice was the best available to them at their scale; at 195 it was not the better choice here. `MAST_common` has since been cleaned to 69 findings and a clean formatter, so the fleet is trending the same way.

**What is deferred is scoped, not global.** `C901` (11 functions) and `BLE001` (33 sites) are `per-file-ignores` with a reason each, so both stay blocking everywhere else and new code cannot add to the pile. Tracked in #72. `N812` is off repo-wide: the `L`/`D`/`T` module aliases are a deliberate convention at ~124 call sites.

**PowerShell gets a parse sweep, not a linter.** `[Parser]::ParseFile` over every `.ps1`/`.psm1`, in the `pester` job. 124 of 160 tracked code files are PowerShell and would otherwise be ungated; the sweep is ~15 lines, needs nothing installed, and closes the failure mode that bit twice this week — a provider script only ever executes *on a unit*, so a syntax error in one surfaces during a production run rather than at review. Verified in both directions on real PowerShell 5.1: clean over the tree, non-zero with a planted syntax error. PSScriptAnalyzer is #73.

**Rejected:**

- **Landing red to match the siblings.** Consistent, and rejected above on the evidence of what permanently-red signals do in this repo.
- **A narrower rule set now, the fleet standard later.** Green immediately and much less work, but it diverges from a standard whose entire purpose is fleet uniformity, and a divergent rule set tends to become permanent. Considered and dropped in favour of clearing the debt.
- **Excluding `vm/` and `tools/` from lint** (80 of the 195). Cheaper, and it writes off the dev harness and one-off tooling as permanently unlinted.
- **Refactoring `_process_unit` to satisfy `C901`.** Complexity 20, and the ordering of its phases is the orchestrator's contract. Doing that inside a lint sweep is how a real regression gets introduced for a style score.
- **PSScriptAnalyzer in this change.** No fleet settings file to inherit, so the rule selection has to be argued from scratch, and it lands its own debt pile — which would reopen the green-vs-red question mid-flight.
- **`pwsh` for the Pester job.** No bundled Pester 3, and 5.1 is what the units run.

**Unsettled:**

- **The workflow has never run.** It is validated structurally (YAML parses; jobs, matrix and step counts as intended) and the parse sweep is proven on real 5.1, but no job has executed on a runner. Until it has, and until each job has been seen to *fail* when it should, this is YAML.
- **`requirements-ci.txt` has no analogue here.** `MAST_common` separates "deps needed to import the package" from dev deps; this repo folds runtime deps into the test job directly. Fine while `server/requirements.txt` is short.
- **The `pester` job pins 3.4.0 to match the units.** If the units ever move to Pester 5, the suites and the pin move together — 112 assertions rewritten. Nothing forces that today.
- **Nothing checks the two config files stay in step with the fleet.** `ruff.toml` was copied from `MAST_common` and adapted; a future fleet-wide change to it will not propagate here on its own.
