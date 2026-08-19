---
decided: 2026-08-19
status: proposed
issue: MAST_provisioning#54
areas:
  - operator tooling
  - service logon sessions
  - drift
---

# Per-user desktop state is written into the target hive and re-asserted at every logon

**Why:** `#54` asks for two things on a machine that lives in a dome and is reached over NoMachine: a dark Windows theme, night-vision-friendly at the telescope, and a dark background carrying the machine's identity -- above all the hostname -- so a remote session can tell at a glance which unit it is looking at. Both are `HKCU` settings belonging to the autologin `mast` account, and provisioning runs over WinRM as an administrator or as SYSTEM. Nothing in the provider model addressed that gap; the ticket guessed at "the first-logon apply task or a default-user-hive write at bootstrap," and neither is quite what the machines need.

**What:** one provider, `server/providers/desktop-appearance/`, at order 2750 -- after `desktop-shortcuts` (2700) so the operator-desktop modules sit together, and far after `config-bootstrap` (150), whose `C:\WIS\config.toml` supplies the site and role on the image. It carries three separable pieces, and the separation is the design:

`render-desktop-background.ps1` draws the background with `System.Drawing` into `C:\ProgramData\MAST\desktop\background.png` -- machine-wide, once, from `$env:COMPUTERNAME` plus the `site` and `machine_role` read out of the deployed config (never derived from the hostname, per the standing rule). It writes a sidecar `background.json` recording the static fields and a `${RendererVersion}`, which is what makes staleness detectable at all.

`mast-userhive-lib.ps1` resolves the target user's hive: mounted at `HKEY_USERS\<sid>` when the account is signed in, or `reg.exe load`ed from its `NTUSER.DAT` when it is not. On a provisioned unit the mounted case is the *normal* one, not an error path -- bootstrap enables Winlogon auto-logon for `mast` (2026-06-29), so from the first boot onward that hive is in use and `reg.exe load` cannot touch it. `Resolve-MastUserHive` returns `$null` only when the account has no profile at all, and throws with `reg.exe`'s exit code when a profile exists but its hive cannot be reached. It has no `HKCU:` fallback by construction.

`apply-desktop-appearance.ps1` runs as `mast` from an AtLogon scheduled task, `MAST-DesktopAppearance-Apply`. It exists for the two things a registry write cannot do: `SystemParametersInfo(SPI_SETDESKWALLPAPER, ...)` to repaint the desktop and a `WM_SETTINGCHANGE` / `ImmersiveColorSet` broadcast to make the shell re-read the theme. Both must originate inside the session. `provide-desktop-appearance.ps1` starts the task immediately when it found the hive already mounted, so the change lands without waiting for a sign-in.

Two departures from the nearest precedent are deliberate. `apply-instrument-profiles.ps1` is one-shot -- sentinel plus self-unregister -- because it materializes files once. This task is neither: appearance is standing state, re-rendered when the machine is renamed or the design changes, and every reboot needs the broadcast again, so a sentinel would pin whatever the first logon happened to see. And the values are written **twice**, once into the hive from provisioning and again by the task in-session; that is not redundancy but the two halves of the problem -- provisioning can reach the registry and not the desktop, the task can reach both but only exists once someone signs in.

`verify-desktop-appearance.ps1` answers *is it current?* rather than *is it present?*, which resolution rule 2 in `docs/per-module-tracking-plan.md` requires of exactly this kind of generated artifact. It compares the sidecar's static fields against the live machine -- so a renamed unit reports `background STALE` instead of quietly keeping an image that names the wrong host -- and compares all five deployed registry values against what this build writes, reading them back through the same resolver the provider wrote through, so the check cannot be inspecting a different user than the one configured.

**Rejected:**

- **Sysinternals BGInfo**, which is the obvious answer and was the first recommendation. It ships already: `Bginfo64.exe` is inside `server/providers/sysinternals/assets/SysinternalsSuite.zip` and lands on `PATH`. Its configuration is a **binary `.bgi`**, authorable only through its GUI -- an asset nobody can read, diff or amend in review, in a repo whose per-module hashes and decision records exist to make changes legible. Its one real advantage is live fields, and `#54` asks for *static* information. The seam is left open rather than closed: dynamic content lands in the renderer and in the sidecar's `dynamic_fields` list, which verify skips, and moves the image from one machine-wide copy to a per-user one -- a change to `apply-desktop-appearance.ps1` alone, since that script already reads the image path out of the sidecar rather than from a constant.
- **A default-user-hive write at bootstrap**, the ticket's other suggestion. It seeds only profiles created afterwards, and `C:\Users\mast` already exists on every provisioned unit -- so on today's fleet it would reach nothing. Not built as a supplement either, since no future account on a unit needs it yet.
- **A one-shot AtLogon task doing all the work**, matching `instrument-profiles` exactly. Simpler to copy, and it would leave the theme un-applied on any unit until someone signed in, with nothing machine-side to verify against in the meantime.
- **Rendering into the user profile** (`%LOCALAPPDATA%`) instead of `C:\ProgramData`. It is where BGInfo would put it and where the dynamic path will eventually go, but a per-user image cannot be verified from a provisioning session that has no such session, and the non-elevated task cannot write to a ProgramData folder SYSTEM created -- so today the machine copy is the artifact and the task only points at it.
- **Restarting `explorer.exe`** to make the last few shell surfaces follow the theme immediately. Provisioning may be running against a session someone is watching.

**Unsettled:**

- **None of this has run on Windows.** It was written on a Mac, where `System.Drawing`, the hive resolution, the scheduled task and the P/Invoke are all unexercisable, and PSScriptAnalyzer could not be run locally either. The dev VM is the first real test and has to be the *interactive* session, not headless. This record is `proposed` for that reason and is rewritten to what shipped before it is flipped.
- The claim that `reg.exe load` fails on a signed-in user's hive is reasoned from the locking, not observed; the lib logs the actual exit code so the first real failure is on record. `#106` carries the same uncertainty for `bootstrap-winrm.ps1`.
- **The theme is only mostly live before a reboot.** Applications and most of the shell follow the broadcast; a few Explorer surfaces are believed to need an `explorer.exe` restart, which is not done.
- Whether `1920x1080` with `WallpaperStyle=10` (Fill) reads well in a NoMachine session sized smaller than the render is untested. The text block sits in the lower-left, away from the single `Desktop\MAST` folder icon and away from the right and bottom edges, on that assumption.
- The renderer's font is `Segoe UI`. It has not been confirmed present on the units' Windows 10 IoT Enterprise LTSC image, and `System.Drawing` substitutes silently rather than failing if it is absent.

**Implications:** `mast-userhive-lib.ps1` is the first shared answer in this repo to "write a per-user setting from a provisioning run," and the `-lib.ps1` suffix puts it under `test_provider_commandfiles.py`'s staging guard automatically. `client/bootstrap-winrm.ps1`'s `Set-MastHkcu` has the defect this lib is built not to repeat -- it silently retargets the administrator's hive when the load fails -- and is `#106`, fixed locally rather than by sharing this code, because bootstrap runs before any staging exists. The remaining `#54` item is the observatory-ready sweep (lock screen, night light, screen-off policy), which this provider is the natural home for.
