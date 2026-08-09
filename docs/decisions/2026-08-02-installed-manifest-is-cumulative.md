---
decided: 2026-08-02
status: accepted
issue: MAST_provisioning#22
areas:
  - drift
  - providers
  - failure reporting
---

# `installed-manifest.json` is cumulative, per-module, and written even on partial runs

**Why:** Execute copied `build-manifest.json` wholesale and stamped `installed_at`,
which made the unit's record **last-payload-only**: a `-Modules <subset>` touch-up
overwrote the document with just that subset, so the unit could no longer answer
"am I fully provisioned". The write was also gated on `failCount -eq 0`, so a run
where a single module failed wrote nothing at all and the record kept describing a
payload from days earlier -- the next cycle could not tell which modules were
actually current.

**What:** `client/mast-installed-manifest.ps1` (dot-sourced by execute, staged
beside it, unit-testable without a provisioning run) merges per-module entries
`{version, hash, provide, verify, installed_at}` for the modules a run actually
touched; untouched modules keep their prior entry. `provide` and `verify` are
tracked separately because a module can install and then fail its own verify, and
because a module with no verify command records `none` rather than a false `pass`.
Written on **every** run, partial included. `fully_provisioned` is derived: every
module the build declares is present, hash-matched, `provide = pass`, not
`verify = fail`.

**Rejected:**

- **Keeping the copy-the-build-manifest approach and only fixing the failure gate.**
  Rejected because the deeper bug is the wholesale copy: a `-Modules` subset run
  would still erase every other module's record, so "am I fully provisioned" stays
  unanswerable even when every run succeeds.
- **Writing the manifest only on a clean run** (the existing `failCount -eq 0` gate).
  Rejected as exactly backwards -- the run that fails is the one whose record matters
  most, and suppressing the write leaves the unit describing a payload from days
  earlier while quietly looking authoritative.
- **Recording one pass/fail per module.** Split into `provide` and `verify` instead,
  because a module can install successfully and then fail its own verify, and the two
  need different remedies. A module with no verify command records `none` rather than
  a false `pass`, so absence of evidence is not stored as evidence.
- **Storing `fully_provisioned` as a written field.** Derived instead, from the
  build's module list plus the per-module entries, so it cannot go stale relative to
  the data it summarizes.

**Unsettled:**

- **A partial run leaves the aggregate `payload_hash` absent**, so the fast path in
  `check-and-provision.ps1` and `server/prov/driver.py` misses and the unit falls
  through to a run rather than being skipped as current. Absent must never read as a
  match, which is why the PS driver's read was made explicit rather than relying on a
  silent `$null` from a missing property -- but that is a rule enforced by having
  noticed it once, not by the type system.
- **`tools/fleet-drift-report.py` still reads the now-absent `module_versions`** from
  the installed manifest and is rewritten in Stage 3 to key on `modules`. Until then
  the report and the manifest disagree about where the truth lives.
- **A legacy pre-`modules` manifest is read without error and carries nothing
  forward**, which is the intended one-time mast01-04 migration. Whether every
  production unit's legacy document actually has the shape assumed here was not
  checked against all four.

**Implications:** The unit can answer "which modules am I current on?" for the first
time, including after a run that failed part-way. Tests:
`server/tests/mast-installed-manifest.Tests.ps1`.
