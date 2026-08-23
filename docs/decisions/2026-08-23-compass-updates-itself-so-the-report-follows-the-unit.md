---
decided: 2026-08-23
status: accepted
issue: MAST_provisioning#137
areas:
  - providers
  - drift
  - reproducibility
  - failure reporting
---

# Compass updates itself, so the report follows the unit rather than the asset

**Why:** `assets/mongodb-compass-1.43.0-win32-x64.exe` is committed, LFS-tracked and version-pinned, and it decides what a unit installs exactly once. Compass ships Squirrel's `Update.exe` and fetches its own updates from MongoDB's feed. Measured on mast07 hours after provisioning, with no run in between:

```
app-1.43.0 : 360,300,551 bytes      <- what provide-mongodb-client.ps1 installed
app-1.49.14: 477,619,472 bytes      <- what Compass fetched for itself
Update.exe : present, v2.0.1.1
```

Six minor versions in an afternoon. mast01-mast06 had never been checked and are each on whatever they last pulled.

This is #133's problem shifted in time. The Jupyter stack drifted **at provision time**, where a lockfile in `commandfiles` fixes it because a run is the only thing that can change the answer. Compass drifts **after** provisioning, on the unit's own schedule, so no lock can hold it -- provisioning is not running when the change happens.

**What:**

- **The drift is accepted.** Compass keeps its updater. It is an operator convenience for inspecting the unit database, nothing in the science path imports it, and no other module asserts a Compass version. Freezing it would buy reproducibility nobody is spending and cost the security fixes an internet-facing Electron app accumulates.
- **`Get-MastCompassApp` replaces `${appDirs}[0]`.** Squirrel keeps each build in its own `app-<version>` directory and marks a superseded one with a `.dead` file. The old selection took `Get-ChildItem`'s first result, which is the alphabetically first name: `app-1.43.0` sorts before `app-1.49.14`, so on a drifted unit the size assertions measured the **dead** tree while the unit ran the live one, and the check passed by looking at the wrong thing. Selection now skips what Squirrel marked dead, then takes the highest version -- `.dead` first, because it is Squirrel's own statement about which build is current and a rollback marks the newer one dead. `compass-app.ps1` holds this and is dot-sourced by both scripts.
- **A unit records what its modules FOUND, not only whether they passed.** `installed-manifest.json` tracked per-module `provide`/`verify` outcomes and a payload hash -- enough to answer "is this unit up to date with the build", and structurally unable to answer "what is on it". A `facts` block now rides in each module's entry, written by `Write-MastModuleFacts` into `C:\MAST\status\facts\<module>.json` and folded in by `execute-mast-provisioning.ps1`. `mongodb-client` reports `compass_version`, `compass_installer_version` and `mongosh_version` -- and deliberately not a `compass_self_updated` boolean, which is exactly the first two compared and would be a second place for one truth to be wrong. Facts carry what cannot be derived from other facts.
- **The fleet report is the point of it.** `tools/fleet-drift-report.py` renders a facts matrix with a `*` on any fact the fleet disagrees about, and carries the same cells into `--csv`. "Which Compass is each unit running" is now one read against the registry instead of an SSH session per unit.
- **The version report lives in verify, not the provider.** `provide-mongodb-client.ps1`'s top guard exits the whole script once `mongosh.exe` and `%LOCALAPPDATA%\MongoDBCompass\MongoDBCompass.exe` exist, so on a steady-state unit it never reaches the verification block -- and a unit that updated Compass after provisioning is precisely the unit the provider does not see. `verify-mongodb-client.ps1` (which replaces the inline one-liner that was in `module.json`'s `verify` key, same mongosh check, same log and smoke paths) runs every pass, so it is the only place that can observe this. The provider reports too, for the run that installs.

**Three properties of the facts channel are load-bearing:**

- **Facts are observations, never checks.** Nothing in `fully_provisioned` reads them. A module reporting a surprising value still passes if its verify passed, because the alternative turns an accepted steady state into a red run on every unit -- which is how a check trains its reader to ignore it.
- **Attached only to modules the run touched**, exactly like the entries themselves. A `-Modules git` touch-up leaves `mongodb-client`'s facts as they were rather than refreshing facts for a module it never looked at. `observed_at` is stamped so a reader can tell an old observation from a fresh one, and is excluded from the fleet comparison -- it differs on every unit by construction, so counting it would mark every module divergent.
- **The sidecar is replaced, not merged.** A module states its whole fact set in one call. Merging would keep a fact alive after the code that produced it was deleted, which is the stale-annotation problem in another costume.

**Rejected:**

- **Suppressing the updater** -- via Compass's `autoUpdates` preference, a read-only configuration, or denying execute on `Update.exe`. This is what #133 did for Python and it would make the asset mean what it appears to mean. Not taken because the pin is not load-bearing here: no other module depends on a Compass version, so the reproducibility gained is unspent, while the cost is a permanently ageing browser engine on a unit and a mechanism to maintain. Reconsider the moment anything starts depending on Compass behaving a particular way.
- **Reporting only into the verify log.** This was the first cut of this change, and it was too weak: it made the answer *knowable* while leaving it one SSH session per unit away, which is the same reason nobody knew mast01-mast06's versions in the first place. A fact nobody can aggregate does not answer a fleet question. The argument is on #137.
- **Bumping the asset to 1.49.14.** It would match today's mast07 and be wrong again next month, at 153 MB per bump. The asset's job is a working first install.
- **A per-module `report` command in `module.json`**, beside `command` and `verify`. Cleaner in principle -- facts would not depend on a verify script running -- but it adds a third command kind to the payload, the build, the driver's module filter and the outcome map, to serve one module. The sidecar needs nothing from the driver but a directory.
- **Failing the module when a unit has drifted.** See the first load-bearing property above.

**Unsettled:**

- **Facts are only as fresh as the last run that touched the module.** A unit that has not been provisioned in a month reports a month-old Compass version, and the manifest says so via `observed_at` rather than by refusing to answer. `run-verify-only.ps1` refreshes the sidecars but does not currently rewrite the manifest, so tier-2 observations do not reach the fleet report.
- **Facts are untyped and unvalidated.** Any module can write any key; nothing declares a schema or catches a typo, and the fleet report renders whatever it finds. Deliberate for now -- the alternative is a registry to maintain before knowing what modules want to report.
- **Compass may not be the only self-updating asset.** It was caught because #118 sent someone looking. Within `mongodb-client` it is alone -- `mongosh` and the Database Tools are plain zips -- but the other providers have not been swept for vendor updaters.
- **A superseded build can sit on disk indefinitely.** Squirrel deletes a `.dead` directory on a later launch, so a unit whose operator never opens Compass keeps both trees, ~840 MB on mast07. Reported, not collected.
- **The pin still holds for the first install, and only that.** Nothing acts on a unit whose Compass has moved several major versions; the fleet report shows it and a human decides.
