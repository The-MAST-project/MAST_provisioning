---
decided: 2026-08-09
status: accepted
issue: MAST_provisioning#57
areas:
  - drift
  - providers
  - fleet migration
---

# The installed manifest validates each carried-forward entry, not the manifest as a whole

**Why:** `Merge-MastInstalledManifest` in `client/mast-installed-manifest.ps1` carried the previous manifest's `modules` forward wholesale, on a premise stated in its own comment: that a legacy pre-`module_state` manifest "has no `modules` key -- there is simply nothing to carry." That premise was believed when Stage 2 of the per-module tracking work was written, and it was wrong about the actual fleet. mast01-04's legacy manifests do carry the key, holding the older *list* of module names. Enumerating a list's `PSObject.Properties` yields `System.Array`'s own members, so `Count`, `Length`, `LongLength`, `Rank`, `SyncRoot`, `IsReadOnly`, `IsFixedSize` and `IsSynchronized` were written into the unit's manifest as though they were modules, and then re-copied verbatim on every later run.

Found on 2026-08-09 while completing the fleet migration: three of the four production units carried the eight phantom entries and mast02 did not, the difference being that mast02 was the one unit with no pre-existing manifest to carry anything forward from.

The same legacy shape had already produced a different failure three days earlier. `prov.drift.classify` raised `AttributeError: 'list' object has no attribute 'get'` on it and blocked the whole migration; that was fixed in `abe0828` by treating a non-map `modules` as state unknown. The reader was given a guard and the writer was not, so the shape kept costing us twice.

**What:** a new `Test-MastModuleEntry` predicate accepts exactly the two shapes `Get-MastEntryField` already reads -- an `IDictionary` built during this run, or a `PSCustomObject` parsed from a previous run's JSON -- and rejects everything else. Step 1 of the merge now applies it per entry and skips what fails.

Two tests were added to `server/tests/mast-installed-manifest.Tests.ps1`, and both were confirmed to fail against the unmodified merge before the guard landed (9 modules where 1 was expected, 10 where 2 were expected): one for a legacy manifest whose `modules` is a list of names, and one for a manifest an earlier run already polluted.

**Rejected:**

- *Guarding the whole manifest instead of each entry* -- mirroring the Python fix literally, by refusing to carry anything when `modules` is not a map. It handles the legacy list, but not a unit already polluted: those units now hold a structurally valid map whose *entries* are the problem, so a manifest-level test passes and the phantoms survive forever.
- *A one-time prune, in a script or folded into the #41 deletion commits* -- correct, but it adds one-time machinery to the issue whose entire purpose is deleting one-time machinery, and it only runs where someone remembers to run it. Per-entry validation makes the next ordinary run do the same work with nothing to remember and nothing to delete afterwards.
- *Filtering by name against a known list of `System.Array` members* -- fixes the symptom observed rather than the class. Any other non-map value reaching that map would pass.

**Unsettled:**

- The units shed the phantoms on their **next provisioning run**, not on merge of this change. Until each unit has run, its manifest still carries them, and `tools/fleet-drift-report.py` still shows them as `extra*`.
- Nothing validates the manifest at *read* time. The consumers reached today all iterate the module list the build declares, so a junk entry beside real state is inert -- but that is a property of the current consumers rather than a guarantee, and #44 intends to build `remove` and `report` on this map.
- Whether any *other* consumer of the legacy shape is still unguarded was not audited. Two were found by accident, three days apart, in two languages. The shape is known to exist on production units and a deliberate sweep for readers of `modules` was not done.

**Implications:** the manifest is the per-unit package database #44 builds on, so keeping non-module values out of it matters more than the currently inert symptom suggests. The cleanup rides on ordinary provisioning cycles, which means #41's deletions do not need to carry a data-repair step.
