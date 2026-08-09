---
decided: 2026-08-02
status: accepted
issue: MAST_provisioning#22
areas:
  - drift
  - failure reporting
  - orchestration
---

# Smoke gates only what ran, and the report and driver share one set of unit paths

Second and final batch of #33 review fixes; the first batch settled the design in
`2026-08-02-per-module-drift-decides-what-runs.md`.

**Why:**

1. Phase 9 checked smoke markers for the unit's FULL module set with no freshness
   check, which targeting made wrong in both directions. Markers live in a persistent
   directory and are only rewritten by the module that runs, so an untargeted module
   "passed" on a marker from an older payload -- assurance the gate had not earned.
   Worse, a module whose marker went missing (logs cleaned) failed the unit
   permanently: drift never targets it because its hash matches, so execute never
   regenerates the marker and there is no path out.
2. `write_csv` still read `module_versions` after the matrix moved to hash-keyed
   statuses, so one run emitted a text report saying STALE and a CSV showing no drift
   -- and this very PR's desktop-shortcuts change (verify command gained
   `-FastApiUrl`, no version bump) is exactly that case.
3. The unit-side `validation.json` path was spelled in both the driver and the tool.
4. `_build_manifest` was per-unit state on the long-lived `Driver`.
5. `load_reference` lost its last caller.

**What:**

1. Smoke asserts over `target_modules or modules` -- what this run actually executed.
   Absence of a marker for an untouched module is not a health signal; the computed
   tier-2 verify is what answers that.
2. `write_csv` emits the same cells `render` does, read off `cmp["matrix"]`.
3. New dependency-free `server/prov/unit_paths.py` holds the shared unit-side
   literals; the driver and `tools/fleet-drift-report.py` both import it. It imports
   nothing on purpose -- the report runs with no third-party deps in `--from-json` mode
   and must not pull in `prov.transport` (paramiko/pywinrm) to learn a path.
4. `_build` returns the manifest as a third element and the caller keeps it local,
   like `target_modules`.
5. Deleted.

**Rejected:**

- **Adding a freshness check to the full-set smoke gate** -- comparing each marker's
  timestamp against the payload -- rather than narrowing what is gated. Rejected
  because it keeps asserting over modules this run did not touch, which is a question
  smoke markers are not the right instrument for. The computed tier-2 verify answers
  "is an untouched module still healthy?"; smoke answers "did what just ran work?"
- **Regenerating missing markers for untargeted modules** so the permanent-failure
  trap cannot happen. Rejected as treating the symptom: it would have execute write
  assurance for work it did not do.
- **Having `fleet-drift-report.py` import the driver's path constants from
  `prov.transport`** or another existing module. Rejected on a concrete constraint --
  the report runs with no third-party dependencies in `--from-json` mode, and pulling
  in paramiko or pywinrm to learn a string would break that. `unit_paths.py` imports
  nothing on purpose.
- **Leaving the duplicated `validation.json` literal** with a comment. Two spellings
  of one path had already produced a class of bug in this review pass.
- **Keeping `load_reference`** in case a caller returns. Deleted -- dead code that
  reads as supported is worse than an absent function someone re-adds deliberately.

**Unsettled:**

- **`unit_paths.py` is a new shared surface with a rule that is not enforced.** Its
  no-imports property is what makes the report work dependency-free, and nothing
  prevents a future edit from importing something and breaking that silently.
- **The CSV/text divergence was caught by review, not by a test**, because the fleet
  report had no tests at all before this pass. It gained its first
  (`server/prov/tests/test_fleet_report.py`, loaded by path since the tool is a
  hyphenated script) covering `compare_to_build`, the CSV/text agreement, both manifest
  shapes, and tier-2 parsing.
- **Both manifest shapes are still supported** in the report, so the legacy path
  remains live and tested rather than retired.

**Implications:** Suite is 125 pytest, up from 106 before the review.
