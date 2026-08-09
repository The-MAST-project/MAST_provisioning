---
decided: 2026-08-02
status: accepted
issue: MAST_provisioning#22
areas:
  - drift
  - orchestration
  - providers
  - failure reporting
---

# Per-module drift decides what runs: two tiers, one classifier

**Why:** The driver compared a single `payload_hash`, so any difference meant a
full cycle -- every module reinstalled because one changed. And the comparison
could not distinguish "the payload changed" from "the unit broke": a stopped
service leaves the hash matching perfectly.

**What:** `server/prov/drift.py` classifies each module as up-to-date /
needs-update / missing / extra / needs-repair from the unit's cumulative
`installed-manifest.json` vs the payload's `build-manifest.json`, keyed on the
**content hash** (the version string is reporting only, per the epic's locked
decision 2). The driver passes the drifted set to execute as `-Modules`, so a
one-module drift runs one module.

**The per-module compare runs before the aggregate-hash skip.** The hash decides
only whether a no-drift result means "skip" or "run the full set" -- it is a
*fast-skip input*, not a gate. Running it first made the tier-2 verdict below
unreachable for the case it exists for (see *Rejected*).

**Targeting happens at execute, not at build.** The build stays full; only
execution is narrowed.

**Two tiers, one vocabulary.** Tier 1 is the written record. Tier 2 is computed:
`client/run-verify-only.ps1` (already the verify dispatcher -- extended rather
than duplicated into a new `validate-unit.ps1`) writes
`C:\MAST\status\validation.json`, and a module whose hash matches but whose
live verify fails classifies **needs-repair**. Absent tier-2 data means "not
run", never "failed", so a unit that has never run verify-only is not
manufactured into drift. `needs-update` wins over `needs-repair` when both
apply -- the remedy differs and the payload change is the larger fact. A tier-2
entry whose report `checked_at` predates that module's `installed_at` is ignored:
it describes a build no longer on the unit. An unparseable timestamp keeps the
verdict rather than silently suppressing a reported failure.

**Order-terminal providers survive targeting.** `module.json` gains
`"always": true`, collected by the build into `build-manifest.json`'s
`always_modules`; `DriftReport.targets` folds them into any non-empty target set
in build order, while `DriftReport.drifted` still reports what actually drifted.
They never cause a run on their own.

**Content-aware verify (resolution rule 2).** `verify-desktop-shortcuts.ps1` was
presence-only, so the epic's worked example -- repointing the FastAPI shortcut --
passed it. It now takes `-FastApiUrl` injected from `module.json`'s verify
command (the same place the provider's arg comes from, so the two cannot drift)
and compares the deployed `.url` target against what this build expects. Adding
the arg also folds it into the module's content hash, which hashes resolved
commands.

**Rejected:**

- **Comparing the aggregate `payload_hash` first, as a gate.** This was the first
  implementation, and reviewing #33 showed it made the tier-2 `needs-repair` verdict
  **unreachable for the case it exists for**. The unit publishes an aggregate hash only
  when it is fully provisioned -- every module hash-matched and clean -- which is exactly
  the state a runtime failure arises in (payload unchanged, service died). The driver
  returned `already_current`, so `classify()` never ran and `validation.json` was never
  read. Demoting the hash to a fast-skip input costs one pure-logic classification per
  cycle over data already fetched.
- **Targeting strictly by module name, with no always-run set.** Also tried, and it
  **dropped the order-terminal providers**: `execute-mast-provisioning.ps1` filters
  commands strictly by module, so a `-Modules zwo` run skipped `reboot` (order 9999),
  `mast-services-finalize` (9500) and the order-9000 `proxy` re-assert -- an installer's
  pending reboot would leave no flag and the orchestrator would never learn.
- **Hardcoding the order-terminal providers in the driver** (`reboot`,
  `mast-services-finalize`, `proxy`) once that gap was found. Rejected as a list that
  drifts from the providers themselves; `"always": true` declared on the module keeps the
  fact where the module is defined.
- **Letting always-run modules trigger a run on their own.** They fold into a non-empty
  target set only -- otherwise every cycle would run something and the no-drift skip
  would never fire.
- **Trusting tier-2 data regardless of age.** Nothing clears `validation.json`
  (`run-verify-only.ps1` is its only writer and is operator-run), so a pre-repair `fail`
  re-targeted the repaired module on every later payload change, indefinitely. Comparing
  `checked_at` against `installed_at` decides staleness from the data itself.
- **Having `run-verify-only.ps1` clear `validation.json`** at the start of a provisioning
  run instead. Not taken: it is operator-run, so making the driver depend on an operator
  action ordering is fragile.
- **Building only the drifted subset.** The obvious alternative, and wrong in a way worth
  recording: the payload's `build-manifest.json` would then declare only that subset, and
  the unit's `fully_provisioned` -- judged against the build's module list -- would read
  true after a one-module run.
- **Keying drift on the version string.** Rejected per the epic's locked decision 2: a
  `git`-resolved version moves on commits that change nothing this module deploys, and
  fails to move when a build-time arg changes.
- **A new `validate-unit.ps1` for tier 2.** Rejected in favor of extending
  `client/run-verify-only.ps1`, which is already the verify dispatcher -- a second entry
  point would mean two things that run verifies and can disagree.
- **Treating absent tier-2 data as a failure.** Absence means "not run"; the alternative
  would make every fresh unit look broken.
- **Actioning `extra`** -- a module the unit has and the build no longer ships. It is
  reported and never acted on: removing software is out of scope for a drift pass, and a
  drift pass that uninstalls things is a much larger promise than one that installs them.
- **Suppressing a tier-2 verdict with an unparseable timestamp.** Deliberately the other
  way: silently dropping a reported failure is the worse error.

**Unsettled:**

- **`validation.json` still has no lifecycle.** Staleness is detected rather than
  prevented, and the file accumulates entries nobody clears.
- **`always_modules` is a new build-manifest field** with a single intended use; nothing
  validates that a module declaring `"always": true` is genuinely order-terminal, so the
  mechanism is available to be misused.
- **Three defects in the first shape of this design were found by review, not by tests**,
  and two of them only manifest in scenarios the suite did not construct. What else the
  suite does not construct is unknown.
- **Four drift flow tests were asserting the wrong thing** -- they asserted no exit code
  and were in fact ending at `EXIT_UNIT_FAIL` on a missing smoke marker. They now answer
  smoke for the build's modules and assert `EXIT_OK`. Tests that passed for the wrong
  reason were present in this area once.
- **The content-aware verify fix is one module deep.** `verify-desktop-shortcuts.ps1` was
  made content-aware because it was the epic's worked example; every other presence-only
  verify has the same blind spot and was not swept.
- **`tools/fleet-drift-report.py` imports the same `classify`** so the report cannot
  disagree with what the next cycle will do; its old cross-unit modal comparison remains
  as the no-`--build-manifest` fallback, which means two code paths with different
  accuracy depending on how it is invoked.

**Implications:** A one-module drift runs one module. `fleet-drift-report.py` grew a
Tier-2 section: it had parsed `validated_at` and never rendered it, which is what let the
staleness problem stay invisible. Also removed while settling this design: a dead
`inst_hash == _UNKNOWN` comparison and an unreachable `build_modules` fallback. Tests:
`server/prov/tests/test_drift.py` and the targeted-update cases in `test_driver_flow.py`.
