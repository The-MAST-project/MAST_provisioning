---
decided: 2026-08-03
status: accepted
issue: MAST_provisioning#31
areas:
  - source-layout
  - services
  - fleet migration
---

# The stage-6 migration is a supervised tool with preconditions, and renames rather than deletes

**Why:** Retiring a unit's pre-mast-clone `C:\MAST\repos` by hand is a
destructive step repeated across four production units, in a state where the
dangerous mistake is invisible: a new `C:\MAST\src` that *looks* complete while
`mast-unit` still runs the OLD per-repo venv. Deleting then kills the running
unit. It also cannot be folded into the autonomous loop -- it stops a service and
removes a tree, one-time work that should not live in the routine cycle.

**What:** `tools/migrate-unit-to-mast-clone.py`, supervised, one unit at a time,
**dry-run by default**. The decision is pure logic in `server/prov/migration.py`
so the preconditions are testable without a unit
(`server/prov/tests/test_migration.py`, 13 cases weighted toward the refusals).
It refuses unless the new layout is demonstrably good: venv interpreter,
`mast.pth`, all three role clones, `common/__init__.py`, and the service already
re-pointed. A blocked unit keeps a working old tree -- the failure mode to avoid
is a unit left with neither.

**Renames, not deletes.** Default is `C:\MAST\repos.retired-<stamp>`, which
satisfies every consumer (nothing looks for that name) and stays reversible on a
production unit for the cost of a few GB; `--purge` deletes. Service `StartType`
is never touched -- `mast-services-finalize` owns run state and deliberately
leaves MAST services Manual at this stage -- and the prior run state is restored
rather than assuming "running". Post-checks re-probe and exit non-zero, so a
half-migration cannot read as success.

**Rejected:**

- **Folding the migration into the provisioning loop** as a one-time module. Rejected
  on principle and on blast radius: it stops a service and removes a tree, which is
  not routine-cycle work, and an unattended loop doing it across four production units
  removes the supervision that catches the invisible failure.
- **Deleting `C:\MAST\repos` outright.** Renaming to `repos.retired-<stamp>` satisfies
  every consumer -- nothing looks for that name -- and stays reversible on a production
  unit for the cost of a few GB. `--purge` exists for when a unit is trusted.
- **Applying by default with a `--dry-run` opt-in.** Inverted deliberately: dry-run is
  the default and `--apply` is explicit, because the operator running this is doing it
  four times in a row and the fourth time is when the habit costs something.
- **Assuming the service should end up Running.** Rejected -- the prior run state is
  restored instead, and `StartType` is never touched, because `mast-services-finalize`
  owns run state and deliberately leaves MAST services Manual at this stage. A
  migration that "helpfully" starts a service would silently override that decision.
- **Listing every non-standard entry in the warning.** Tried and rejected on the
  evidence: it buried the signal under ~24 provisioning sidecar logs
  (`<repo>.git-trace.log` and friends), and on mast02 the entries that matter
  (`mast-claude-config`, `PlaneWave_PlateSolve3_Catalog`) would have been invisible in
  that wall of names. The warning considers **directories** only.

**Unsettled:**

- **A rename retains the sidecar logs**, which per issue #17 contain the (now expired)
  token in `GIT_TRACE` output. So the tidier end state is `--purge` once a unit is
  trusted, and until then every migrated unit keeps a copy of the old secret on disk.
- **Verified against the VM, not against a production unit.** The dry run reported
  `ready`, `--apply` stopped the service, renamed the tree to
  `repos.retired-20260803-091325`, restored Running, and post-checks passed. A follow-up
  provisioning cycle then produced the first fully clean module verify -- `mast verify
  ok: 3 clone(s) current under C:\MAST\src` -- with the only remaining harness failure
  being the pre-existing `unit heartbeat` on `:8000`, which fails identically on the
  pre-migration baseline. The four production units are the real test.
- **The preconditions encode what was known to go wrong.** They check that the new
  layout is demonstrably good; a way for a unit to be broken that nobody has seen would
  pass them.
- **Disk cost is unbounded across the fleet** while renamed trees are kept, and nothing
  reclaims them.

**Implications:** #17's exposed token leaves the units only when `--purge` runs or the
retired trees are otherwise removed.
