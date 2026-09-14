---
decided: 2026-09-14
status: accepted
issue: MAST_provisioning#207
areas:
  - orchestration
  - providers
---

# The background is rendered after the manifest is written, and by the elevated session

**Supersedes** the placement decided in the 2026-09-14 entry "The background states what the unit records", which kept the render in the `desktop-appearance` provider and added an AtLogon comparison to correct it afterwards. The source of the date was right; where it was read was not.

**Why:** the `provisioned` line comes from `installed-manifest.json`, which `execute-mast-provisioning.ps1` merges **after** the command loop. `desktop-appearance` renders from **inside** that loop, so it reads the manifest as it stood before the run and paints the previous run's date. mast04 was provisioned 2026-09-14 and stated 2026-09-02, twelve seconds of file timestamps apart:

```
background.png           rendered 17:47:47
installed-manifest.json  written  17:47:59
```

mast07 hid this for a day by being provisioned four times on 2026-09-14. The 11:54 run wrote the manifest **without** running `desktop-appearance`; the 13:22 run then rendered and found today's date already on disk. Two runs in sequence produce a correct wall, one run does not, and one run is the normal case. The lesson is not about the wallpaper: a unit re-run several times in a day is exactly the unit a fix gets verified on, and it is the least representative one available.

The compensation was already in the right *place* — `execute` starts `MAST-DesktopAppearance-Apply` immediately after writing the manifest — but it delegated the work to a task that is `RunLevel: Limited` against an image where `BUILTIN\Users` holds `ReadAndExecute` only. Every boot on every unit logged the staleness correctly and then failed in `Bitmap.Save`, which GDI+ reports as its generic error, into a catch that downgraded it to a log line. That path has never succeeded once (#206).

**What:** `Update-MastStaleBackground` in `mast-appearance-lib.ps1` holds the compare and the render. `execute-mast-provisioning.ps1` dot-sources the staged lib and calls it at the point it already reached — manifest on disk, session elevated — and then starts the apply task as before, for the broadcast, which is the one thing only the logon session can do.

The provider's own render is unchanged and still runs: it is what creates the image on a machine that has none, and the re-render here is a no-op when the date already agrees.

**Rejected:**

- **Making the render an always-module.** The reason it cannot be one is unchanged and is what the first attempt missed: `mast-services-finalize` is order 9500 and still inside the command loop, so even the last module runs before the manifest exists. No ordering within the loop can fix a dependency on something written after it.
- **Moving the manifest write earlier, before the loop.** `installed_at` would then claim a run that had not happened, and a run that failed halfway would leave the claim behind — the property the manifest was given in the first place.
- **Rendering per-user at logon so a reboot alone corrects the date.** Genuinely wanted, and the growth seam in `render-desktop-background.ps1` already describes it, but it is a change to where the image lives and what `verify-desktop-appearance.ps1` compares. Left to #206 rather than folded in here.
- **Granting the `mast` account Modify on the appearance directory.** Two lines, and it would have made the existing AtLogon path work — but it lets a non-elevated user rewrite a machine-wide artifact the desktop reads, and it fixes the weaker of the two defects. Also deferred to #206.

**Unsettled:**

- **A failed re-render is still only a log line.** The catch in the apply task returns success, so `LastTaskResult` is 0 and nothing surfaces. `verify-desktop-appearance.ps1` does raise a stale image as needs-repair, which is what caught this at all, but the silent-failure shape is what let it run for a day.
- **The lib is dot-sourced from `C:\ProgramData\MAST\desktop`**, so `execute` depends on the provider having run at least once on that machine. The guard reports it and continues, which is right for a first provisioning, but it means the very first run of a new unit still paints from the provider's in-loop render.
