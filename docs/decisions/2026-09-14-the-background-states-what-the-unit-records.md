---
decided: 2026-09-14
status: accepted
issue: MAST_provisioning#200
areas:
  - providers
  - drift
  - reporting
---

# The background states what the unit records, and says so or says unknown

**Why:** mast07's desktop read **"MAST unit   provisioned 2026-09-02"** on a machine provisioned 2026-09-14 (`run-20260914-115415`, `UNIT_OK`, 8/8 modules smoked). A wallpaper is the one surface an operator reads without asking for it, and this one made a false claim about the machine it was painted on.

Two defects produced it. `render-desktop-background.ps1` set the label from `Get-Date` — the date the *image* was made, printed as the date the *unit* was provisioned, which coincide only on a run that happened to re-render. And nothing re-rendered: `provide-desktop-appearance.ps1` renders, while the AtLogon task runs `apply-desktop-appearance.ps1`, which reads the image path from the sidecar and applies it without re-rendering. Once per-module drift landed (#22) a run that targets `desktop-appearance` became the exception, so the image froze at whichever run last did.

**What:** one invariant, held by several independent mechanisms.

> The background displays a provisioning date **iff** that date equals `installed_at` in the unit's `installed-manifest.json`. Otherwise it displays `unknown`.

`Get-MastProvisionedDate` reads that manifest. Absent, unparseable, empty or non-date all return the string `unknown` — never `Get-Date`, never a blank that reads as *recent*, never the raw field echoed onto a wall. A machine that has never completed a run says so. A run that failed before the manifest merge leaves no claim behind, because `installed_at` is only written by a run that got that far.

The date joins `Get-MastAppearanceFields`, which is the function the renderer and `verify-desktop-appearance.ps1` both call — the existing "two independent readings" design. That is what makes the check free: verify already compares every `static_fields` key against a fresh reading, so a stale image is now a failing check, hence a tier-2 `needs-repair`, hence repaired by the ordinary drift loop.

Three chances to converge, none load-bearing alone:

- **At logon**, `apply-desktop-appearance.ps1` compares the sidecar's `provisioned` against a fresh reading and re-renders before applying when they differ. Covers a reboot with no provisioning involved. Best-effort: a failed re-render logs and applies the existing image, because a stale wallpaper beats no wallpaper and verify reports it either way.
- **At end of run**, `execute-mast-provisioning.ps1` starts the already-registered AtLogon task.
- **Next run**, via verify → `needs-repair` → the module is targeted and re-renders.

**The end-of-run refresh cannot be a module, and that is the sharp part.** `installed_at` is written by `Merge-MastInstalledManifest` at `execute-mast-provisioning.ps1:421`, *after* the module command loop at line 237. Every module therefore runs before the current run's date exists. `mast-services-finalize` is the obvious hook — already an always-module, order 9500 — and it is inside that loop, so a render from there would paint the **previous** run's date, permanently one run behind. It would have looked correct on the second run, which is what makes it worth a decision record rather than a comment. The refresh sits after line 421 instead, beside the reboot handler, and `test_desktop_refresh_contract.py` asserts that ordering so it cannot quietly move.

**Rejected:**

- **`"always": true` on `desktop-appearance`.** The obvious fix: re-render every run. Rejected on what `always_modules` is for — order-terminal cross-cutting providers (`reboot`, `proxy`, `mast-services-finalize`) — and the 2026-08-02 drift record's own warning that the mechanism is "available to be misused". A wallpaper is not order-terminal, and this would re-render on every cycle to correct a field that changes once per run.
- **Changing the label to "rendered".** Truthful, cheap, and throws away the fact anyone wants. The label was not the thing that was wrong.
- **Taking the date from the run id** (`run-20260914-115415`, available in the staging path). It is present at module time, which is exactly why it is tempting — and it names a run that may still fail, so it would claim a provisioning that did not complete.
- **Making the refresh fatal.** A run whose modules all succeeded should not fail because a wallpaper did not repaint. Verify reports it; the drift loop fixes it.

**Unsettled:**

- **A unit that never logs out relies entirely on the end-of-run trigger.** mast07 has held a console session since 3 Sep. If `Start-ScheduledTask` does not reach the user's session, the image waits for verify to flag it and the next run to repair it — a cycle, not an hour.
- **`unknown` has never been seen on a real machine.** Every fleet unit has an `installed-manifest.json`; the path is exercised only by tests.
- **The task name is duplicated** between `provide-desktop-appearance.ps1` and `execute-mast-provisioning.ps1`, which cannot import from each other. A static test asserts they match; nothing prevents a third copy.
