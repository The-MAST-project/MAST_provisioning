---
decided: 2026-08-20
status: accepted
issue: MAST_provisioning#106
areas:
  - bootstrap
  - operator tooling
  - service logon sessions
  - failure reporting
---

# Per-user state belongs to provisioning, not to bootstrap

**Why:** `client/bootstrap-winrm.ps1` applied eleven per-user quieting values -- `ToastEnabled` and nine `ContentDeliveryManager` keys -- through a helper, `Set-MastHkcu`, whose fallback was `HKCU:`. `HKCU` is the hive of whoever runs bootstrap, which the surrounding comment itself said is normally not `mast`, so on the fallback path the values configured the operator's own account and `Set-ItemProperty` succeeded. Bootstrap then printed `Windows popup/notification suppressions applied.` That was filed as `#106` after `#54`'s desktop work built a resolver specifically to avoid the same shape.

Reading it to fix it produced a worse finding than the ticket described. `#106` reasoned that a first bootstrap on a fresh image would load the hive correctly and that the exposure was a *re-run* against a unit where auto-logon had since locked it. The opposite is true: `New-LocalUser` creates `mast` a few dozen lines above the block, so at that point the account has existed for seconds and has never logged on. It therefore has no `ProfileList` entry and no `NTUSER.DAT` -- the same fact the 2026-08-03 instrument-profiles decision records for provisioning time, which is *later* still. So the load was skipped and the fallback taken on **every** ordinary bootstrap, and there is no reason to believe any unit's `mast` account ever received these values.

That reframes the fix. Repairing the resolution in place would have made bootstrap correctly refuse, since on a fresh machine there is genuinely no hive to write to -- honest, and the values would stay unapplied forever.

**What:** the eleven values moved into the `desktop-appearance` provider, which already owns the `mast` account's theme and wallpaper and already resolves the hive properly. Bootstrap keeps the machine-wide half of that section -- the two Windows Backup reminder tasks -- and its closing message now says only that.

They did not move as eleven more inline writes. `Get-MastDesktopUserValues` in `server/providers/desktop-appearance/mast-appearance-lib.ps1` is now the single table of every per-user value the operator desktop owns, fifteen of them, and it has three consumers: `provide-desktop-appearance.ps1` writes it into the target hive through `Set-MastUserHiveValue`, `apply-desktop-appearance.ps1` re-asserts it in the live session at each logon, and `verify-desktop-appearance.ps1` compares what is deployed against it. Before this the theme and wallpaper were spelled out separately in all three, which is the drift the table removes; adding the quieting to three places instead of one would have tripled it.

Sequencing is what makes the move safe rather than merely tidier: bootstrap runs before any profile exists, provisioning runs after, and a unit is operated later still. Nothing is lost by quieting the desktop at order 2750 instead of at first touch.

**Rejected:**

- **Seeding `C:\Users\Default\NTUSER.DAT` from bootstrap** so the `mast` profile would inherit the values when auto-logon creates it. This is the one situation where a default-hive write earns its keep, and it would have kept the values at first touch. Rejected because it widens the blast radius to every profile ever created on the machine to serve one account, and because it leaves per-user desktop state owned in two places -- which is the condition that produced this defect.
- **Fixing the resolver in place and leaving the block in bootstrap.** Smaller diff, matches the ticket as filed, and its honest outcome on a fresh machine is a warning that the suppressions could not be applied -- the reporting defect fixed and the substantive one left.
- **A first-logon scheduled task registered by bootstrap**, mirroring `instrument-profiles`. It would reach `mast`'s real hive and nothing else, but it duplicates in bootstrap the task the provider already registers, on a machine that has no staging yet.

**Unsettled:**

- **No unit is known to have had these values applied**, so the fleet's `mast` accounts have presumably been running with toasts and content-delivery suggestions enabled. Whether that has ever been observed during an observing session is unknown; nobody reported it, which is weak evidence either way.
- **The operator hives that received the writes are not cleaned up.** Whoever ran bootstrap on each unit has these eleven values set in their own profile. Harmless, and identifying those accounts after the fact is not worth it -- but the change is not a full revert of what happened.
- **`RotatingLockScreenEnabled` is in the moved set and is about the lock screen**, which the remaining `#54` sweep item also covers. The two will need reconciling when that item is worked, rather than each assuming it owns the value.
- The 2026-08-19 record on this provider says `#106` would be "fixed locally rather than by sharing this code, because bootstrap runs before any staging exists." The premise held; the conclusion did not survive one day of contact with the code. That record is `accepted` and stays as written -- what it states is what was believed on the day.

**Implications:** `CLAUDE.md`'s per-user-settings rule now says per-user state goes in a provider and names `Get-MastDesktopUserValues` as the one place to add such a value. `mast-userhive-lib.ps1` no longer describes `Set-MastHkcu` as a live defect. Bootstrap's remaining per-user surface is nil, which is the property worth preserving.
