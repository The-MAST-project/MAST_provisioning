---
decided: 2026-08-20
status: accepted
issue: MAST_provisioning#116
areas:
  - drift
  - failure reporting
  - providers
---

# A check that did not run is not a check that does not exist

**Why:** the per-module manifest recorded `verify` as `pass`, `fail` or `none`, and `none` was doing two jobs. It is the value `Add-MastModuleOutcome` initialises an entry with, so it meant nothing more precise than *"no `*-verify` command for this module ran in this pass"* — which covers both a module that declares no verify at all (`reboot`, and it never will) and a declared verify that did not run. The first is clean. The second is unknown. They were the same string.

Both readers treat `none` as clean: `fully_provisioned` accepts it explicitly ("absence of a check is not a failed check") and `prov.drift.classify` only ever tested `== "fail"`. So an unknown would have been read as settled, and the module would stop being targeted for a check nobody performed.

**Nothing was misreporting when this was written.** Every path that could leave a declared verify unrun was traced: `build-mast.ps1` emits a `<module>-verify` command only where `module.json` declares one; the `-Modules` filter strips the `-verify` suffix and matches base names, so it cannot take one without the other; a failed provide does not suppress the verify (mast05 recorded `mongodb-client provide=fail verify=pass`); and a run that dies mid-loop writes no manifest at all. `none` therefore did mean "not declared" in every reachable case. This is hardening a value that was true by circumstance into one that is true by construction — and giving the next feature that *can* skip a verify somewhere honest to land.

**What:**

- A fourth state, `skipped`. `none` = the payload declares no command of that kind. `skipped` = it declares one and this pass did not run it.
- `New-MastModuleOutcomeMap` now takes the command list and seeds each declared command as `skipped`; `Add-MastModuleOutcome` overwrites with `pass`/`fail` as each reports. Whatever is still `skipped` at write time provably did not run. The map could not have derived this itself: it only ever sees commands that ran, so the declared set had to come in from `commands.json`.
- `fully_provisioned` blocks on `skipped`. `prov.drift.classify` treats it as not-clean, so the module is re-targeted.

**Seeded from the FILTERED command list, and that is load-bearing.** `Merge-MastInstalledManifest` overwrites exactly the entries in the outcome map and carries every other one forward untouched — the property that stops a `-Modules` subset erasing the rest of the record. Seeding from the unfiltered list would put every excluded module in the map as `skipped` and overwrite the very entries a partial run exists to preserve, turning a fix for one unknown into a much larger fabricated one.

**Rejected:**

- **Inferring it on the read side** — have `drift.classify` compare the manifest against the build's declared command set and decide `none` means skipped when a verify exists. It needs no writer change and heals old manifests, but it puts the meaning of a recorded value somewhere other than the record, and it is wrong whenever the build has moved on since the unit last ran.
- **Making `skipped` a warning rather than a block.** It would keep today's `fully_provisioned` results identical by construction. But that flag is what the autonomous loop trusts to skip a unit entirely, and "we did not check" is not a basis for skipping.
- **Recording a reason string** (`skipped: filtered`, `skipped: aborted`) instead of a bare state. More useful to a human, and unfalsifiable here: nothing currently produces a skip, so every reason string would be invented rather than observed.

**Unsettled:**

- **`skipped` is currently unreachable**, so the stricter `fully_provisioned` rule changes no unit's status today. That makes it safe to land and also means the new path is untested outside its unit tests — the first thing to actually produce a `skipped` will be its real trial.
- **Old manifests keep `none` under the old meaning.** Harmless, since `none` reads clean either way, and the first re-run of each unit rewrites the entries. Nothing migrates them, so for a while `none` in the fleet means "not declared, probably".
- **`provide` gained the same treatment for symmetry** without a case demanding it. A provide that is declared and does not run is as unreachable as the verify one.
