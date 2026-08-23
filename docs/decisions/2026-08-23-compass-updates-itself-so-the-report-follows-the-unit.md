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

Six minor versions in an afternoon. mast01-mast06 have never been checked and are each on whatever they last pulled.

This is #133's problem shifted in time. The Jupyter stack drifted **at provision time**, where a lockfile in `commandfiles` fixes it because a run is the only thing that can change the answer. Compass drifts **after** provisioning, on the unit's own schedule, so no lock can hold it -- provisioning is not running when the change happens.

**What:**

- **The drift is accepted.** Compass keeps its updater. It is an operator convenience for inspecting the unit database, nothing in the science path imports it, and no other module asserts a Compass version. Freezing it would buy reproducibility nobody is spending and cost the security fixes an internet-facing Electron app accumulates.
- **The report follows the unit.** `verify-mongodb-client.ps1` records the build actually on disk, the version the staged installer ships, and the difference between them, and **passes either way**. A self-updated unit is the expected steady state, not a fault.
- **The version report lives in verify, not in the provider.** The provider's top guard exits the whole script once `mongosh.exe` and `%LOCALAPPDATA%\MongoDBCompass\MongoDBCompass.exe` exist, so on a steady-state unit `provide-mongodb-client.ps1` never runs past line 74 -- and a unit that updated Compass after provisioning is precisely the unit the provider does not see. Verify runs every pass, so it is the only place that can observe this. The provider reports too, for the run that installs.
- **`verify` became a script.** It was a ~600-character one-liner in `module.json`'s `verify` key; it is now `verify-mongodb-client.ps1`, with the same `mongosh --nodb --eval 'print(version())'` check and the same `Get-MastVerifyLog` / `Write-MastSmokeOk` paths.
- **`Get-MastCompassApp` replaces `${appDirs}[0]`.** Squirrel keeps each build in its own `app-<version>` directory and marks a superseded one with a `.dead` file. The old selection took `Get-ChildItem`'s first result, which is the alphabetically first name: `app-1.43.0` sorts before `app-1.49.14`, so on a drifted unit the size assertions measured the **dead** tree while the unit ran the live one, and the check passed by looking at the wrong thing. Selection now skips what Squirrel marked dead, then takes the highest version -- `.dead` first, because it is Squirrel's own statement about which build is current and a rollback marks the newer one dead. `compass-app.ps1` holds this and is dot-sourced by both scripts; `server/tests/compass-app.Tests.ps1` covers the mast07 case, numeric-not-textual comparison (`app-1.10.0` over `app-1.9.0`), and the dead-marker rules.

**Rejected:**

- **Suppressing the updater** -- via Compass's `autoUpdates` preference, a read-only configuration, or denying execute on `Update.exe`. This is what #133 did for Python and it would make the asset mean what it appears to mean. Not taken because the pin is not load-bearing here: no other module depends on a Compass version, so the reproducibility gained is unspent, while the cost is a permanently ageing browser engine on a unit and a mechanism to maintain. Reconsider the moment anything starts depending on Compass behaving a particular way.
- **Failing the module on drift.** It would turn the expected steady state into a red run on every unit, which is how a check trains its reader to ignore it.
- **Bumping the asset to 1.49.14.** It would match today's mast07 and be wrong again next month, at 153 MB per bump. The asset's job is a working first install.
- **Recording the live version in `installed-manifest.json`.** The right long-term home -- the manifest is what a fleet report reads, and the verify log has to be fetched per unit. Not done here because the manifest tracks `provide`/`verify` outcomes per module and has no channel for module-reported facts; adding one is a driver change, not a provider change.

**Unsettled:**

- **The pin still holds for the first install, and only that.** Nothing detects a unit whose Compass has moved several major versions, or one where an update broke it. Verify reports; nobody reads it unless something else has already gone wrong.
- **Compass may not be the only self-updating asset.** It was caught because #118 sent someone looking. Within `mongodb-client` it is alone -- `mongosh` and the Database Tools are plain zips -- but the other providers have not been swept for vendor updaters.
- **A superseded build can sit on disk indefinitely.** Squirrel deletes a `.dead` directory on a later launch, so a unit whose operator never opens Compass keeps both trees, ~840 MB on mast07. Reported, not collected.
