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
- **Drift:** `server/prov/driver.py` compares the
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

## Resolution requirement

Tracking must detect a change to **any deployed artifact a module produces** —
including generated and argument-driven ones — not just a bumped `version` or an
edited primary script. **Worked example that must register as drift:** repointing
the FastAPI desktop shortcut from `http://localhost:8000/` to `.../docs` (the #8
item). That target lives in the `desktop-shortcuts` **`module.json` `command`
args** (`-FastApiUrl ...`), *not* in its `commandfiles`; and its
`verify-desktop-shortcuts.ps1` checks only that the `.url` files **exist**, never
where they point. So a naive design (hash `commandfiles`, verify presence) leaves
the stale shortcut **invisible to both** the build hash and the verify. Two rules
follow, baked into the stages:

1. **The per-module hash must cover every determinant of the module's deployed
   output** — the `commandfiles` bytes **plus the `module.json` `command` string
   and its args, plus `version`** (plus any build parameter that shapes the
   output, e.g. `-Site`). If an input changes what gets deployed, it must be
   inside the hash boundary.
2. **Tier-2 verify must answer "is it *current*?", not just "is it present?"**
   for staleness-sensitive artifacts (shortcut targets, config-file contents,
   `.reg` values): compare the deployed artifact's content/target against what the
   current build would produce, not mere existence. Today's `verify-*.ps1` are
   largely presence-only, so making the staleness-sensitive ones content-aware is
   explicit tier-2 scope.

This is the general resolution bar for the whole epic; the stages below are
written to meet it, and any provider whose output is generated or arg/config-
driven (shortcuts, config-bootstrap, first-logon `.reg` imports, instrument
profiles) is audited against both rules.

## The `mast` module — a source-tracked special case (amended 2026-08-02)

The `mast` provider is the one module whose deployed output is not a function of
this repo at all: `provide-mast.ps1` clones the repos listed in `mast-repos.txt`
and builds a per-repo `.venv` from each repo's `requirements.txt`. Its
determinants are therefore the **upstream commits** and the **resolved Python
dependency set** — neither of which lives under `server/providers/mast/`.

**Upstream pinned its dependencies (Jul–Aug 2026)**, which changes what is
achievable here. `MAST_unit.2024-12-12` ("Pin requirements to the live
environment", then "Prune dev-only linters…"), `MAST_control` + `MAST_gui`
(pinned jointly, exact `==` including transitives), `MAST_spec`, and
`MAST_common` (shared `ruff.toml`, `ruff==0.16.0`) are now all pinned. Before
that, the same inputs produced a *different* venv on different days as PyPI
moved, so no hash over repo-tracked inputs could ever have described the `mast`
module's output — Resolution rule 1 was unsatisfiable for it. With exact pins
the deployed venv becomes a deterministic function of the checked-out commit,
and the rule is reachable.

Stage 1 as landed does **not** yet reach it, and fails in both directions:

- **Blind to real drift.** `module_state.mast.hash` folds in `version`, and
  `version: "git"` resolves to *this* repo's SHA (`Get-GitSha -RepoTop $Top`).
  Every upstream commit — including the pin commits above — changes what a unit
  receives and changes the hash by nothing.
- **Noisy with false drift.** Conversely, any unrelated commit to
  MAST_provisioning rotates that SHA and so rotates `mast`'s hash. Stage 3 would
  then re-run the heaviest module (clone, venv, pip, service restart) on
  essentially every build — the exact outcome targeted updates exist to avoid.

Compounding both: `mast-repos.txt` pins **branch refs**, and the existing-clone
path does `fetch` + `reset --hard FETCH_HEAD`, so the deployed content moves
under a fixed hash by design.

**Amendment:** for source-tracked modules the hash folds in the **resolved
upstream commit SHAs**, not this repo's SHA. `version` keeps reporting the
provisioning SHA (locked decision 2 already separates hash-as-truth from
version-as-reporting). Per-stage consequences are in the stages below.

## Stages

### Stage 1 — Per-module content hash in `build-manifest.json` (build side)

- In `build-mast.ps1`'s existing per-module flatten loop (`foreach ($m in
  $Modules)`), compute each module's content hash over **all determinants of its
  deployed output** (per Resolution rule 1), *not* just the payload bytes:
  - its **source `commandfiles`** under `server/providers/<module>/` — **not** a
    staging subdir (staging is flattened) — via the `Get-PayloadHash`
    rolling-SHA-256 algorithm (`<commandfile-relative-path>:<sha256>`, sorted);
  - **plus the resolved `module.json` `command` string and its args** (this is
    what makes the FastApiUrl→`/docs` repoint register as drift; today it lives
    only in `command`);
  - **plus the `version`** and any build parameter that shapes the module's
    output (e.g. `-Site`, which selects the weather URL default).
  Source-tracked `mast` (version `git`) folds the git SHA in, consistent with
  today's `module_versions` — **superseded for `mast` by Stage 1b below.**
- Extend `build-manifest.json` with a `modules` map: `{ <module>: { version,
  hash } }` (fold the existing `module_versions` into it, or add alongside and
  deprecate). **Keep the aggregate `payload_hash`** as the fast top-level
  "anything changed at all?" gate.
- **Tests:** per-module hash determinism; a changed file in one module changes
  only that module's hash; schema; `-TestMode` optional-payload skips don't
  crash the per-module hash.

**Status:** landed as `module_state` (commit `890fa22`,
docs/decisions/2026-07-23-build-manifest-per-module-content-hashes.md),
with `build/build-manifest-lib.ps1` + `server/tests/build-manifest-lib.Tests.ps1`.

### Stage 1b — Resolve upstream refs for source-tracked modules (added 2026-08-02)

Fixes the two-directional `mast` defect described above.

> **Sequencing — do `docs/mast-clone-adoption-plan.md` first.** That change
> retires the `mast` provider's own clone/venv code in favor of
> `tools/mast-clone.ps1 -Role unit`, and **deletes `mast-repos.txt`**, which this
> stage is written against. After it lands, 1b resolves refs from
> `tools/mast-repos.tsv` (rows whose `roles` include `unit`) and folds the
> manifest's `#!uv-version` directive into the hash as a further determinant.
> The unpinned-`pip` gap noted below also disappears there — mast-clone uses
> pinned uv with one joint resolve. Implementing 1b first means writing it twice.

- At manifest time, `git ls-remote` each `mast-repos.txt` entry to a concrete
  commit SHA and record it in `module_state.mast` as `repos: { <repo>: <sha> }`.
  A repo pinned to a SHA in `mast-repos.txt` resolves to itself; a branch ref
  resolves to that branch's current tip.
- Fold **those SHAs** into `Get-ModuleContentHash` in place of the
  provisioning-repo SHA for source-tracked modules. `MAST_common` is a submodule
  of `MAST_unit.2024-12-12`, so the parent SHA transitively covers the pinned
  common commit; the separate `MAST_common` clone still resolves on its own line.
- `version` continues to report the provisioning SHA — human-readable, not the
  drift signal.
- **Cost / alternative:** this needs network at build time. The build host
  already has it (the clones are token-authenticated over HTTPS), but if that
  dependency is unacceptable, the fallback is to **exclude `version` from
  `mast`'s hash** — this kills the false drift but leaves the blindness, pushing
  all upstream-currency detection into Stage 4.
- **One determinant still outside the boundary:** `provide-mast.ps1` runs an
  unpinned `pip install --upgrade pip` and installs with plain `pip` (no
  `--no-deps`, no `--require-hashes`), while the control side builds its venv
  with `uv venv` + `uv pip install` — which is why MAST_control deliberately
  *dropped* its own `pip` pin. With transitives pinned the resolved sets should
  agree, but the installer is now the last unpinned input to the module's
  output. Decide it explicitly rather than by omission.
- **Tests:** ref resolution (branch → tip, SHA → itself); an upstream SHA change
  changes only `mast`'s hash; an unrelated provisioning commit does **not**
  change it; `ls-remote` failure fails the build loudly rather than emitting a
  manifest with a silent gap.

### Stage 2 — Cumulative per-module `installed-manifest.json` (install side)

- `execute-mast-provisioning.ps1`: stop copying `build-manifest.json` wholesale.
  For each module **actually run** this execute, **merge** an entry into
  `installed-manifest.json`: `{ version, hash, installed_at, provide, verify }`,
  each outcome one of `pass | fail | none | skipped` (amended 2026-08-20 —
  `none` means the payload declares no command of that kind, `skipped` means it
  declares one this pass did not run; before the split both read `none` and an
  unknown was indistinguishable from a non-existent check).
  Untouched modules' entries **persist** — a `-Modules` subset no longer wipes
  the record. This fixes the last-payload-only gap.
- Derive `fully_provisioned` (installed set ⊇ the build's module set, all hashes
  matching) and keep an aggregate `payload_hash` for the existing fast path.
- **Record observed, not declared, state for `mast`** (added 2026-08-02). The
  build manifest can only say what it *intended* to deploy; a branch ref may have
  moved between manifest time and clone time, and the pull path
  (`fetch` + `reset --hard FETCH_HEAD`) will happily land on a different commit.
  `provide-mast.ps1` already runs `git rev-parse HEAD` per repo and logs it —
  capture those actual SHAs into the installed entry (`repos: { <repo>: <sha> }`)
  instead of copying the build's value. This is what makes the moved-branch case
  detectable at all.
- **Legacy/migration:** already-provisioned units (mast01–04) carry the old
  whole-document manifest with no `modules` map. On the first per-module cycle,
  treat a missing `modules` map as "state unknown" → recompute (Stage 4) or
  reprovision; documented as a one-time migration (like the `machine_role`
  worked-example in #14).
- **Tests:** merge semantics (a partial run preserves other modules' entries);
  schema; verify-outcome recorded; legacy manifest handled, not crashed.

**Status:** landed (`7b773d6`) — `client/mast-installed-manifest.ps1` +
`server/tests/mast-installed-manifest.Tests.ps1`,
docs/decisions/2026-08-02-installed-manifest-is-cumulative.md.
Decided during implementation: the manifest is written on **every** run, partial
included, and `payload_hash` is published only when `fully_provisioned` — so a
partial run cannot make the driver's fast path skip the unit. **Pester not run**
(developed on macOS; no PowerShell).

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

**Review fixes (2026-08-02, pre-merge).** Three defects found reviewing #33:
the tier-2 `needs-repair` verdict was unreachable (the aggregate-hash gate
returned `already_current` before `classify()` ran, and that gate is only
satisfied in exactly the state a repair arises in); targeting dropped the
order-terminal providers (`reboot`, `mast-services-finalize`, the order-9000
`proxy` re-assert), so an installer's pending reboot left no flag; and a stale
`validation.json` re-targeted a repaired module forever, nothing being its
writer but an operator. Fixed by classifying before the hash gate, a
`module.json` `"always": true` flag carried to `build-manifest.json` as
`always_modules`, and ignoring a tier-2 entry whose report predates the module's
`installed_at`. See docs/decisions/2026-08-02-installed-manifest-is-cumulative.md.

**Status:** landed (`04d4ee7`) — `server/prov/drift.py` + `test_drift.py` +
targeted-update cases in `test_driver_flow.py`; 106 pytest pass, ruff clean.
Decided during implementation: **targeting is applied at execute, not at build**
— building the drifted subset would make `build-manifest.json` declare only that
subset, and Stage 2's `fully_provisioned` would then read true after a one-module
run. The build stays full; `-Modules` is plumbed through the detached runner.

### Stage 4 — Computed tier-2 validation via `verify-*.ps1` (the repair check)

- A `validate-unit.ps1` (or a driver step) re-runs each module's `verify-*.ps1`
  on the unit to compute **live** state, independent of the written manifest →
  catches **runtime drift** (service stopped, file deleted) where the hash still
  "matches" but the module is broken → classifies **needs-repair**.
- **Verifies must be content-aware where staleness matters (Resolution rule 2).**
  Today's `verify-*.ps1` are largely presence-only — e.g.
  `verify-desktop-shortcuts.ps1` only `Test-Path`s the `.url` files, so a shortcut
  pointing at a stale target passes. Upgrade the staleness-sensitive verifies to
  compare the deployed artifact's **content/target** against what the current
  build would produce (shortcut target URLs, config-file values, first-logon
  `.reg` imports, instrument profiles). This is the detection path for
  determinants the fleet-uniform build hash can't see per-unit (e.g. a
  site-derived weather URL) and for post-install edits.
- **`verify-mast.ps1` is the highest-value content-aware verify in the set**
  (added 2026-08-02), and upstream pinning is what makes it writable. Today it is
  presence-only: repo dir exists, `.git` exists, `.venv\Scripts\python.exe`
  exists, `mast-unit` service running — a venv resolved months ago against
  different package versions passes cleanly. Against `>=` constraints there was
  no single correct answer to compare to; with exact `==` pins there is. Upgrade
  it to compare (a) `git rev-parse HEAD` per repo against the recorded SHA and
  (b) `pip freeze` in each venv against that repo's `requirements.txt`. This
  catches more real breakage than the desktop-shortcut case that motivated
  Resolution rule 2.
- Reuses the existing per-provider `verify-*.ps1` framing (no new per-module
  dispatch logic). The two tiers: fast written-hash compare (routine loop) +
  content-aware computed re-run (on demand / periodic).
- **Tests:** dispatcher enumerates providers and maps verify exit codes → state;
  a content-aware verify flags a deployed shortcut whose target ≠ expected.

**Status:** landed (`04d4ee7`) — no new `validate-unit.ps1`:
`client/run-verify-only.ps1` was **already** the verify dispatcher, so it was
extended to write `C:\MAST\status\validation.json` rather than duplicated.
`verify-desktop-shortcuts.ps1` is content-aware for the FastAPI target (the
worked example). Absent tier-2 data reads as "not run", never "failed".

## Documentation (per-stage, required)

- Each stage flips the relevant `[PARTIAL]` sections of
  `autonomous-provisioning-requirements.md` (Unit provisioning manifest #3,
  Version / Drift Detection) toward `[DONE]` and adds a `DECISIONS.md` entry.
- `README` / tooling notes for `fleet-drift-report.py`'s new output and
  `validate-unit.ps1`.

## Out of scope (tracked elsewhere)

- **#20** — astrometry `cygwin` pin: lands on v3 **separately** (its own branch).
- Provisioning-version **pinning + rollback** (#8): separate, later.

## Open: overlap with #14 (raised 2026-08-02)

**#14** ("Differential per-module provisioning: per-module hashing, version
pinning + holds, continuous verify") overlaps this epic on all three of its
axes, and upstream has now delivered part of its "version pinning" from the
other side. Two open issues describing one epic is worth collapsing before
Stage 3 starts.
