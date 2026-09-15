---
decided: 2026-09-15
status: accepted
issue: MAST_provisioning#206
areas:
  - service logon sessions
  - failure reporting
  - providers
  - fleet migration
supersedes:
  - 2026-08-19-per-user-desktop-state-is-written-into-the-target-hive-and-re-asserted-at-logon
---

# The provisioning run repaints the operator desktop; no logon task does

**Supersedes** the task half of the 2026-08-19 entry "Per-user desktop state is written into the target hive and re-asserted at logon". That record's hive write is unchanged and still correct, and its record is left `accepted` for that reason; what is retired is `MAST-DesktopAppearance-Apply` and `apply-desktop-appearance.ps1`.

**Why:** the task was created for the one thing a registry write cannot do. `SystemParametersInfo(SPI_SETDESKWALLPAPER, ...)` and the `WM_SETTINGCHANGE` / `ImmersiveColorSet` broadcast only do anything from inside a logon session, and providers were understood to run outside one. That much was right. What the 2026-08-19 record did not account for is `client/mast-run-detached.ps1`, which registers the execute task with `-UserId 'mast' -LogonType Interactive -RunLevel Highest` — so the provisioning run is *already* inside mast's logon session, and elevated as well. The premise that forced a separate task had stopped holding.

Being redundant was not the problem. The task was `RunLevel: Limited` against a machine-wide image under `C:\ProgramData\MAST\desktop`, where `BUILTIN\Users` holds `ReadAndExecute` on the existing `background.png` — a directory `Write` ACE does not grant modify on a file already there. So the re-render it had been given in #200 failed in `Bitmap.Save` every single time it was needed, GDI+ reported its generic error, and the `catch` around it logged a warning and applied the stale image. `LastTaskResult` stayed 0, and both `provide-desktop-appearance.ps1` and `verify-desktop-appearance.ps1` read that 0 as proof the desktop had been repainted. A second code path doing the same job, structurally unable to do half of it, reporting success (#206).

**What:** `Set-MastLiveDesktop` in `server/providers/desktop-appearance/mast-appearance-lib.ps1` now carries what the apply script carried — the `Add-Type` interop, the `Get-MastDesktopUserValues` assertion into `HKCU`, `SystemParametersInfo`, and the broadcast. `client/execute-mast-provisioning.ps1` calls it immediately after `Update-MastStaleBackground`, in one block after `Merge-MastInstalledManifest`, and logs `DESKTOP_APPLIED` or `DESKTOP_APPLY_SKIPPED`. Re-render then repaint, in that order: re-rendering changes the file, and only the repaint makes the running session show it.

`provide-desktop-appearance.ps1` unregisters the task and deletes the staged `apply-desktop-appearance.ps1`, rather than merely not creating them. Every unit in the field has both, and this module's own files changed, so it drifts on all of them and the removal runs once everywhere. `verify-desktop-appearance.ps1` inverts its check accordingly: a unit still carrying the task now fails, where a unit missing it used to.

`Set-MastLiveDesktop` returns without acting when `$env:USERNAME` is not the mast user. `HKCU` is the calling process's hive; the WinRM fallback in `prov/transport.py` does not run as mast, and writing mast's wallpaper and theme into an administrator's hive would succeed and be wrong — the same shape of silent failure this whole record is about.

**Rejected:** *fixing the ACL so the non-elevated task could re-render* — the obvious minimal patch, and the first one considered. It grants `mast` modify on the image to preserve a second path that would still duplicate what the run already does, and it leaves the desktop's visible state owned by a scheduled task whose only outcome signal is an exit code somebody has to read. *Per-user rendering*, moving the image into each profile so a non-elevated task could always write it, was the preferred option while the task was assumed necessary; it is a real design and the renderer's growth-seam comment still describes it, but it buys nothing once the run itself can render and repaint. *Leaving the task registered but inert* was rejected because a registered task nobody maintains is exactly what produced #206.

**Unsettled:** the Windows wallpaper transcode cache (`%AppData%\Microsoft\Windows\Themes`) is not handled. `SystemParametersInfo` refreshes it, so a run with mast signed in — the normal state of an autologin dome machine — leaves it correct. A re-render with mast *not* signed in updates the file and the hive while the cache still holds the old transcode, and the next logon could paint the stale one. Not observed, and not coded against; if it appears, the fix belongs in the same block. Separately, nothing re-renders at boot any more: the AtLogon comparison covered a unit renamed or re-sited without a provisioning run, and that case now shows a wrong background until the next run, which `verify` reports as a failing check.

The interop itself remains unproven by tests, as it was before. The Pester cases in `server/tests/mast-appearance-lib.Tests.ps1` cover the user guard and the missing-image failure; nothing exercises `SystemParametersInfo`, because a test that made it succeed would repaint the machine running the suite.

**Implications:** the desktop's visible state is set by one block, at one moment in the run, and reports itself in the run log rather than in a scheduled task's `LastTaskResult`. The first run on each unit after this lands does the migration — removing the task and the staged script — and `verify` fails any unit it has not reached yet, so the fleet reports its own progress.
