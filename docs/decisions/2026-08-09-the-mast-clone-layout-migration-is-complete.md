---
decided: 2026-08-09
status: accepted
issue: MAST_provisioning#41
areas:
  - source-layout
  - fleet migration
  - services
---

# The mast-clone layout migration is complete, and its machinery is deleted

**Why:** stage 6 of the mast-clone adoption moved units off `C:\MAST\repos` (a clone per repo, a venv per repo, `common` reached through the `src/common` submodule) onto `C:\MAST\src` (one flat layout, one venv, `common` reached through `mast.pth`). It ran on mast01 and mast04 on 2026-08-06 and on mast02 and mast03 on 2026-08-09. All four then reported `mast-verify` passing and `IN SYNC` against the build in `tools/fleet-drift-report.py`.

The machinery that performed it was written to run once per unit, under supervision, and it is destructive: it stops a service, renames a source tree, and re-points a service manager. Everything it acts on is now in the target state, so every remaining run is a no-op that still carries the ability to do all of that. `#41` exists because the deletions are easy to forget and nothing else signals that they are due.

**What:** deleted outright --

- `tools/migrate-unit-to-mast-clone.py`, the supervised per-unit driver
- `server/prov/migration.py`, its decision logic, and `server/prov/tests/test_migration.py`
- the `legacy C:\MAST\repos still present` check in `verify-mast.ps1`, which existed to make the autonomous loop refuse an unmigrated unit
- the NSSM **re-point** branch in `provide-mast.ps1`, whose only purpose was moving a pre-migration service off its per-repo venv

`prov/migration.py` was imported only by the migration tool and its own tests, so nothing in the driver moved. The fresh-registration branch in `provide-mast.ps1` and the `unitMoved`/`Force` restart branch both stay: those serve new units and ordinary updates, not the migration.

`docs/mast-clone-adoption-plan.md` was **archived rather than deleted**, which `#41` offered as an alternative. Three providers cite it for why they delegate to `mast-clone` instead of cloning anything themselves, and `docs/per-module-tracking-plan.md` cites it for sequencing; deleting it would break those and lose the fullest account of the reasoning. It now opens with a completion banner stating that the stages are done, that the tooling to execute them is gone, and that it is a design record rather than instructions.

**Rejected:**

- *Keeping the `verify-mast` legacy check as a safety net.* It was a migration gate, not an invariant. With no unit unmigrated and no tool to migrate one, it can now only fire on a stray directory somebody creates -- a false alarm on a name that no longer means anything. This is the opposite call to the `MAST_PROJECT` assertions kept in the same batch, and the difference is that those describe a state that must never return, while this one describes a transition that has ended.
- *Deleting the adoption plan outright*, as the strict reading of "delete the one-time machinery" suggests. A plan document is not machinery; nothing executes it, and it is cited from live code.
- *Purging the retired trees on the units as part of this change.* Deleting the machinery is a code change; removing 6.16 GB from four production machines is an operational one, and binding them together would mean a code review deciding when the fleet loses its only rollback path. The purge was done the same day as a separate, supervised step (6.16 GB total: 0.90 / 2.93 / 1.44 / 0.89 GB), after checking each tree for process handles and after confirming that mast02's copy of the 1.97 GB PlateSolve 3 catalog installer was byte-identical to labcomp2's canonical `C:\MAST\ps3-catalog\` and therefore not the last copy of an asset #48 flags as unbacked.

**Unsettled:**

- **A unit that missed the migration can no longer be detected by provisioning.** That was the `verify-mast` check's job. The population is closed today (four production units, all migrated; mast00 and mastw are non-production and outside the gate), so the check protects nothing -- but if a unit is ever rebuilt from a pre-migration image, nothing will say so, and the failure will surface as whatever breaks first.
- **There is no longer a rollback path.** With the retired trees purged, a unit cannot be put back on the old layout by renaming a directory; it would have to be re-cloned. That was accepted knowingly, on the strength of all four units running verified on the new layout, and it is the reason the purge was a deliberate act rather than a side effect of this commit.
- Whether `mast00` or `mastw` carry the old layout was not checked; neither is provisioned by this pipeline today.

**Implications:** with both migrations deleted, `#41` has nothing left to track. `config-bootstrap` and `mast` are now ordinary permanent providers with no one-time code in them.
