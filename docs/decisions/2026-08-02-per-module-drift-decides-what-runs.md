---
decided: 2026-08-02
status: accepted
issue: MAST_provisioning#22
areas:
  - drift
  - orchestration
  - providers
---

# Per-module drift decides what runs: two tiers, one classifier

Three defects in this design were found reviewing #33 before it merged and are corrected
in `2026-08-02-drift-review-fixes.md`, which supersedes parts of this record. The
two-tier model and the targeting-at-execute decision below stand.

**Why:** The driver compared a single `payload_hash`, so any difference meant a
full cycle -- every module reinstalled because one changed. And the comparison
could not distinguish "the payload changed" from "the unit broke": a stopped
service leaves the hash matching perfectly.

**What:** `server/prov/drift.py` classifies each module as up-to-date /
needs-update / missing / extra / needs-repair from the unit's cumulative
`installed-manifest.json` vs the payload's `build-manifest.json`, keyed on the
**content hash** (the version string is reporting only, per the epic's locked
decision 2). The driver runs it after the aggregate-hash gate and passes the
drifted set to execute as `-Modules`, so a one-module drift runs one module.

**Two tiers, one vocabulary.** Tier 1 is the written record. Tier 2 is computed:
`client/run-verify-only.ps1` (already the verify dispatcher -- extended rather
than duplicated into a new `validate-unit.ps1`) writes
`C:\MAST\status\validation.json`, and a module whose hash matches but whose
live verify fails classifies **needs-repair**. Absent tier-2 data means "not
run", never "failed", so a unit that has never run verify-only is not
manufactured into drift. `needs-update` wins over `needs-repair` when both
apply -- the remedy differs and the payload change is the larger fact.

**Content-aware verify (resolution rule 2).** `verify-desktop-shortcuts.ps1` was
presence-only, so the epic's worked example -- repointing the FastAPI shortcut --
passed it. It now takes `-FastApiUrl` injected from `module.json`'s verify
command (the same place the provider's arg comes from, so the two cannot drift)
and compares the deployed `.url` target against what this build expects. Adding
the arg also folds it into the module's content hash, which hashes resolved
commands.

**Rejected:**

- **Building only the drifted subset.** The obvious alternative, and wrong in a way
  worth recording: the payload's `build-manifest.json` would then declare only that
  subset, and the unit's `fully_provisioned` -- judged against the build's module
  list -- would read true after a one-module run. The build stays full; only
  execution is narrowed.
- **Keying drift on the version string.** Rejected per the epic's locked decision 2:
  the content hash is the source of truth for "needs update" and the version is
  reporting only. A `git`-resolved version moves on commits that change nothing this
  module deploys, and fails to move when a build-time arg changes.
- **A new `validate-unit.ps1` for tier 2.** Rejected in favor of extending
  `client/run-verify-only.ps1`, which is already the verify dispatcher -- a second
  entry point would mean two things that run verifies and can disagree.
- **Treating absent tier-2 data as a failure.** Rejected explicitly: absence means
  "not run", so a unit that has never run verify-only is not manufactured into
  drift. The alternative would make every fresh unit look broken.
- **Letting `needs-repair` win over `needs-update`** when both apply. The payload
  change is the larger fact and the remedies differ, so update wins.
- **Actioning `extra`** -- a module the unit has and the build no longer ships. It is
  reported and never acted on: removing software is out of scope for a drift pass, and
  a drift pass that uninstalls things is a much larger promise than one that installs
  them.

**Unsettled:**

- **`tools/fleet-drift-report.py` imports the same `classify`** so the report cannot
  disagree with what the next cycle will do; its old cross-unit modal comparison
  remains as the no-`--build-manifest` fallback, which means two code paths with
  different accuracy depending on how it is invoked.
- **Nothing clears `validation.json`.** `run-verify-only.ps1` is its only writer and is
  operator-run, so tier-2 data ages with no lifecycle. (This became one of the three
  review defects.)
- **The content-aware verify fix is one module deep.** `verify-desktop-shortcuts.ps1`
  was made content-aware because it was the epic's worked example; every other
  presence-only verify has the same blind spot and was not swept.

**Implications:** A one-module drift runs one module. Tests:
`server/prov/tests/test_drift.py` and the targeted-update cases in `test_driver_flow.py`.
