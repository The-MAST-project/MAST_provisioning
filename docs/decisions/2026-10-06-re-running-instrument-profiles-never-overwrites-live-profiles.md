---
decided: 2026-10-06
status: accepted
issue: MAST_provisioning#209
areas:
  - instruments
  - providers
---

# Re-running `instrument-profiles` never overwrites a unit's live profiles

**Why:** `provide-instrument-profiles.ps1` deleted `C:\ProgramData\MAST\instrument-profiles` on every run, taking the `.applied` sentinel with it, and registered `MAST-InstrumentProfiles-Apply` again. At the next `mast` logon `apply-instrument-profiles.ps1` copied all ten template `.cfg` files over the live PWI4 settings with `-Force` (`Elmo.L500.Mount.cfg`, the EFA and PWBus controllers and `PWI4.cfg` among them) and `reg import`ed the four PHD2 profiles. So any provisioning run that re-ran this module reset a deployed unit's calibrated COM bindings and PHD2 tuning to the templates, silently. On 2026-10-06 the units recorded three different versions of the module (`cfd5a640` on most, `1c32407b` on mast03, `bd424fd6` on mast02), so the full provisioning run planned for the `pwi4-site` rollout would have done this on at least two units. mast02 and mast07 already had a pending apply: no sentinel, live files present.

**What:**

- **`provide` unpacks over the staging dir** (`Expand-Archive -Force`) instead of deleting it, so `.applied` survives. It registers the apply task only when `.applied` is absent, and logs which branch it took. Deleting the dir also failed outright while an operator's `calibrate-instruments.ps1 -Interactive` shell held it open; unpacking in place does not (#190's structural case).
- **`apply` never overwrites.** It copies a template `.cfg` only where no live file of that name exists, and imports `phd2_profiles.reg` only when `HKCU:\Software\StarkLabs\PHDGuidingV2\profile` has no subkeys. It still writes `.applied` (and still tries to unregister its task; see *Implications*), so mast02 and mast07's pending apply now finds their live files, keeps them, and records the unit as applied.
- **`apply` reads `reg import`'s exit code reliably.** `Start-Process -Wait -PassThru` returned a null `ExitCode` on mast07 on 2026-09-15 (`reg import failed (exit )`), which the old check read as a failure, so that unit was never marked applied. The script now holds the process handle and calls `WaitForExit()`.
- **`verify` accepts `.applied` in place of the task.** The sentinel is what records an apply; the task is no evidence either way, since it outlives the apply on every unit (see *Implications*).
- **Tested end to end**, in `server/tests/instrument-profiles-rerun.Tests.ps1`, against planted files and a throwaway `HKCU:\Software\MAST-Tests-<guid>` key. The same tests fail 5 of 7 against the previous scripts.

**Implications:**

- **Checked on mast07 on 2026-10-06**, the unit in exactly the risky state (no sentinel, live files present, old task pending): the new `apply`, run as `mast`, kept all ten live cfgs and the four PHD2 profiles byte-identical to a backup taken first, wrote `.applied`, and logged each kept file.
- **mast03 shows what this prevents.** Its 2026-09-27 run deleted the sentinel; a provisioning run on 2026-10-06 rebooted it, and the pending logon apply put its live cfgs and PHD2 profiles back to the templates at 13:19 local.
- **The logon task does not actually unregister itself.** It runs as `mast`, unelevated, and cannot delete a task SYSTEM registered; `-ErrorAction SilentlyContinue` hides that, so every applied unit still has it. It fires at each logon and exits on the sentinel, which is harmless now that the sentinel survives a re-run.
- **A change to the template bundle reaches new units only.** Before, a bundle change reached deployed units as a side effect of the wipe, along with every reset. A fleet-wide change to a deployed unit's profile now needs a targeted provider that edits just the fields it owns, the way `pwi4-site` (#237) carries the site. #232's star-mass guard is the first such case.
- **A file dropped from the bundle stays in the staging dir** until removed by hand, since the dir is no longer recreated. Nothing reads a file that is not in the bundle.
- **A unit whose live cfgs predate the apply keeps them.** If PWI4 had been run as `mast` before the first logon task (it is not started at logon, so this is not the normal path), its own default cfgs would be kept rather than replaced by the templates.

**Rejected:**

- *Merge templates field by field into the live cfgs.* Which fields are fleet constants and which are per-unit is not recorded anywhere, so a merge would have to guess, and a wrong guess is the same silent reset this removes.
- *Keep overwriting, but back up first.* It still resets the unit; the backup only makes the reset recoverable after someone notices.
