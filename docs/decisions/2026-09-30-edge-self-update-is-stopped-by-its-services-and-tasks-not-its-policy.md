---
decided: 2026-09-30
status: accepted
issue: MAST_provisioning#230
areas:
  - os patching
  - providers
---

# Edge's self-update is stopped by disabling its services and tasks, not by its policy

**Why.** The #15 fleet survey on 2026-09-30 found Microsoft Edge updating itself on every unit. Its `MicrosoftEdgeUpdateTaskMachine*` tasks had run within a day, and `msedge.exe` updated on 2026-09-24. Its leftovers are the `PendingFileRenameOperations` every unit carries. Edge Update is its own updater, so `windows-update-lockdown`'s knobs (`NoAutoUpdate`, `wuauserv`/`UsoSvc`) do not reach it. The units' browser is Chrome (#191), but people do still open Edge (the `mast` profile's Edge history was touched on 2026-07-30 on mast03 and 2026-08-24 on mast08), so it has to keep working. Nothing embeds it: Edge Update manages only Edge (`{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}`) and itself, and there is no WebView2 runtime.

**What.** `server/lib/mast-edge-update.ps1` is the one definition of "off": `Disable-MastEdgeUpdate` disables the `edgeupdate` and `edgeupdatem` services and the `MicrosoftEdgeUpdateTaskMachine*` tasks; `Get-MastEdgeUpdateState` reads them back; `Test-MastEdgeUpdateOff` is the pure verdict, which Pester tests (`server/tests/mast-edge-update.Tests.ps1`). An absent service counts as off. Three callers:

- `enforce-no-updates.ps1` asserts it on the lockdown's daily and at-startup SYSTEM run. `provide-windows-update-lockdown.ps1` deploys the lib beside it in `C:\ProgramData\MAST\windows-update`, from a new `repofiles` entry in the module's `module.json`.
- `verify-windows-update-lockdown.ps1` **fails** when it is not off. Verify runs right after enforce, so anything still live there was not disabled, rather than having drifted back. This is stricter than the `wuauserv` start mode, which is only reported.
- `mast-os-patch-probe.ps1` reports it as `lockdown.edge_update`, and `prov.os_drift` raises the `edge-update-on` finding, so the fleet report names a unit where it is live.

Edge stays installed and usable; it is frozen, not removed.

**The trial that changed the design (mast01, 2026-09-30).** The plan was the documented Edge Update policy under `HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate` (`UpdateDefault=0`, `AutoUpdateCheckPeriodMinutes=0`, `Update{56EB18F8-…}=0`) as the durable lever, with services and tasks as a best-effort daily re-assert. With all three values written and a forced `MicrosoftEdgeUpdate.exe /ua`, Edge Update logged:

```
[ConfigManager::LoadGroupPolicies][Machine is not Enterprise Managed]
[OmahaPolicyManager::set_policy][Group Policy][[CachedOmahaPolicy][is_initialized][0][is_managed][0][auto_update_check_period_minutes][-1] ...
```

It loads no policy on a machine that is not domain-joined or otherwise managed, and mast01 reports `PartOfDomain = False`. So the policy was dropped entirely, and the key was removed from mast01 again. Writing it would suggest a protection that does not exist. Disabling the services and tasks took effect immediately: `edgeupdate` Auto→Disabled, `edgeupdatem` Manual→Disabled, both tasks Ready→Disabled.

**The observation (mast01, 2026-09-30 to 2026-10-01).** mast01 was left with the services and tasks disabled for a day, and Edge was launched and closed in the `mast` session on 2026-10-01 at 11:36. On re-reading the next day nothing had come back: both services still `Disabled/Stopped`, both tasks still `Disabled`, with their last run times and task files unchanged since 2026-09-30. `MicrosoftEdgeUpdate.exe` had not run again (its prefetch entry and `MicrosoftEdgeUpdate.log` were last written at 10:18 on 2026-09-30), the Service Control Manager logged no Edge service events, and `msedge.exe` stayed at 154.0.4258.37. So a person opening Edge does not revive the updater.

**Rejected.**

- *The EdgeUpdate policy*, above. Also rejected: keeping it "in case a unit is ever enrolled in management", which is speculative and would add an inert value for verify to check.
- *Making the units look enterprise-managed* (MDM enrollment and similar) so the policy loads. Far more invasive than the problem.
- *Uninstalling Edge.* People use it, it is not cleanly removable on this edition (Edge Update itself logs "Edge not uninstallable per regional policy"), and removing it would be a larger change than freezing it.
- *Blocking the updater binary* (ACLs, renaming `MicrosoftEdgeUpdate.exe`). Fragile, and invisible to anyone who later wonders why Edge is old.

**Unsettled.**

- **Other ways the disable could be undone.** A Windows feature update or a fresh Edge install could restore the services or tasks. Neither was exercised; the daily re-assert covers them, and verify fails if one gets through.
- **A frozen Edge stops getting browser security fixes.** Accepted for a browser the units do not depend on. Revisit if #191 does not land, since Edge would then stay the default link handler.
- **Chrome's updater** (`GoogleUpdater…` services and task) keeps running. Whether the units' actual browser should self-update is a separate call, left open on #230.
