# Per-module tracking, targeted updates, and precise drift — plan

Branch: `eli/per-module-tracking` (off `eli/provisioning-v3`). Tracking issue:
The-MAST-project/MAST_provisioning#22. Supersedes the two drift bullets in #8
("Grow fleet drift detection past the MVP" and "installed-manifest.json is
last-payload-only — decide if it should be cumulative").

## Goal

Track provisioning state per **module** — version + content hash + effective
state — so the fleet can (a) **update units one module at a time** and (b)
**detect precise, per-module drift**. This replaces today's whole-payload-hash,
all-or-nothing model, which can tell you a unit differs from the build but not
*which* module, and whose installed manifest cannot even reliably say what is
installed.

## Baseline (what exists today)

- **`build/build-mast.ps1` → `build-manifest.json`:** a single `payload_hash`
  (`Get-PayloadHash`: rolling SHA-256 over every staged file, `relative-path:sha256`
  sorted) plus a `module_versions` map (module → `version` string from each
  provider's `module.json`). **Staging is flattened** — every module's
  `commandfiles` are copied into one staging root (assets to the root by leaf
  name, scripts to the root), so there is *no* per-module subdir to hash.
- **`client/execute-mast-provisioning.ps1` → `installed-manifest.json`:** a
  **whole-document copy** of `build-manifest.json` + an `installed_at` stamp. So
  it is **last-payload-only** — a `-Modules <subset>` touch-up overwrites the doc
  with just that subset and it can no longer answer "is this unit *fully*
  provisioned".
- **Drift:** `server/prov/driver.py` / `check-and-provision.ps1` compare the
  single `payload_hash`. `tools/fleet-drift-report.py` prints a `module_versions`
  matrix, trusting the static file.
- **Per-provider `verify-*.ps1`** already exist (the execute-phase verify steps)
  — reusable as the computed / tier-2 check.

## Locked decisions

1. **Written per-module tracking first; computed (`verify-*.ps1` re-run) as a
   tier-2 pass after.** Written is cheap, extends what exists, and immediately
   enables targeted updates + the precise fleet matrix; computed adds runtime-
   drift detection.
2. **Content hash is the source of truth for "needs update"; the version string
   is for human-readable reporting.** A rebuild with changed bytes drifts even if
   the `version` field wasn't bumped, and vice-versa the report still reads in
   version terms.
3. **Own branch `eli/per-module-tracking` off `eli/provisioning-v3`**, landing back
   onto v3; the tracking issue supersedes the two #8 drift bullets.

## Model

Per module, three facts:

- **version** — from `module.json` (intent: "what release").
- **content hash** — NEW; exact bytes of the module's payload.
- **effective state** — the module's `verify-*.ps1` outcome (does it actually
  work: service up, files present, COM loadable).

Per-module drift is then a precise classification:
**up-to-date** | **needs-update** (installed hash ≠ latest build hash) |
**needs-repair** (live state ≠ recorded; tier-2 only) | **missing** | **extra**.

## Stages

### Stage 1 — Per-module content hash in `build-manifest.json` (build side)

- In `build-mast.ps1`'s existing per-module flatten loop (`foreach ($m in
  $Modules)`), compute each module's content hash from its **source
  `commandfiles`** under `server/providers/<module>/` — **not** a staging subdir
  (staging is flattened). Reuse the `Get-PayloadHash` rolling-SHA-256 algorithm
  scoped to the module's `commandfiles` (`<commandfile-relative-path>:<sha256>`,
  sorted). Source-tracked `mast` (version `rolling`) keys its hash off the git
  SHA, consistent with today's `module_versions`.
- Extend `build-manifest.json` with a `modules` map: `{ <module>: { version,
  hash } }` (fold the existing `module_versions` into it, or add alongside and
  deprecate). **Keep the aggregate `payload_hash`** as the fast top-level
  "anything changed at all?" gate.
- **Tests:** per-module hash determinism; a changed file in one module changes
  only that module's hash; schema; `-TestMode` optional-payload skips don't
  crash the per-module hash.

### Stage 2 — Cumulative per-module `installed-manifest.json` (install side)

- `execute-mast-provisioning.ps1`: stop copying `build-manifest.json` wholesale.
  For each module **actually run** this execute, **merge** an entry into
  `installed-manifest.json`: `{ version, hash, installed_at, verify:
  <pass|fail> }` (the `verify` value captured from that module's verify step).
  Untouched modules' entries **persist** — a `-Modules` subset no longer wipes
  the record. This fixes the last-payload-only gap.
- Derive `fully_provisioned` (installed set ⊇ the build's module set, all hashes
  matching) and keep an aggregate `payload_hash` for the existing fast path.
- **Legacy/migration:** already-provisioned units (mast01–04) carry the old
  whole-document manifest with no `modules` map. On the first per-module cycle,
  treat a missing `modules` map as "state unknown" → recompute (Stage 4) or
  reprovision; documented as a one-time migration (like the `machine_role`
  worked-example in #14).
- **Tests:** merge semantics (a partial run preserves other modules' entries);
  schema; verify-outcome recorded; legacy manifest handled, not crashed.

### Stage 3 — Precise per-module drift + targeted update (driver + fleet report)

- **Driver drift check (`server/prov/driver.py`):** per module, compare
  installed `{version, hash}` vs the latest build `{version, hash}` →
  up-to-date / needs-update / missing / extra. If any module needs update or is
  missing → provision **`-Modules <the drifted set>`** (targeted), not a full
  cycle; if none → skip. This is the "updating" half of the epic.
- **`tools/fleet-drift-report.py`:** upgrade from a version matrix to a per-unit
  × per-module **status** matrix (up-to-date / stale / missing), keyed on hash,
  version shown for readability. This is the multi-unit management surface.
- **Tests:** drift classification (pure logic, table-driven); targeted-module
  selection from a drift set; report rendering incl. missing/extra.

### Stage 4 — Computed tier-2 validation via `verify-*.ps1` (the repair check)

- A `validate-unit.ps1` (or a driver step) re-runs each module's `verify-*.ps1`
  on the unit to compute **live** state, independent of the written manifest →
  catches **runtime drift** (service stopped, file deleted) where the hash still
  "matches" but the module is broken → classifies **needs-repair**.
- Reuses the existing per-provider `verify-*.ps1` (no new per-module logic). The
  two tiers: fast written-hash compare (routine loop) + computed re-run (on
  demand / periodic).
- **Tests:** dispatcher enumerates providers and maps verify exit codes → state.

## Documentation (per-stage, required)

- Each stage flips the relevant `[PARTIAL]` sections of
  `autonomous-provisioning-requirements.md` (Unit provisioning manifest #3,
  Version / Drift Detection) toward `[DONE]` and adds a `DECISIONS.md` entry.
- `README` / tooling notes for `fleet-drift-report.py`'s new output and
  `validate-unit.ps1`.

## Out of scope (tracked elsewhere)

- **#20** — astrometry `cygwin` pin: lands on v3 **separately** (its own branch).
- Provisioning-version **pinning + rollback** (#8): separate, later.
