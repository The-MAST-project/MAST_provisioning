---
decided: 2026-08-24
status: accepted
issue: MAST_provisioning#137
areas:
  - providers
  - licensing
  - fleet migration
---

# A NoMachine seat is a file, and mastw gives one up so mast08 can have it

**Why:** mast08 needs a NoMachine certificate and there was none spare. Eleven hosts want one -- mast00, mastw, mast01-mast07, mast-ns-spec, and now mast08 -- against ten purchased subscriptions.

The shortfall was not visible, because a duplicate was hiding it. Reading the machines:

```
mastw   server.lic  LI06X02774   modified 2026-07-01 15:10:18
mast00  server.lic  LI06X02774   modified 2026-07-01 15:32:21   <- the same subscription
```

The 2026 renewal was hand-installed on the two non-provisioned hosts 22 minutes apart, and whoever did it took `server-01.lic` out of the zip both times instead of following `allocated.csv`. So `server-02.lic` (LI06X02775), the row assigned to mastw, was never deployed anywhere -- it looked spare while actually being mastw's seat, and mastw looked licensed while actually sharing mast00's.

The production units are unaffected: mast01-mast04 and mast-ns-spec each carry the certificate `allocated.csv` assigns them, mast01-mast04 having landed within two seconds of each other on 2026-07-07 (a provisioning run, not a person).

**What:**

- **mastw releases its seat.** `etc\server.lic` renamed aside on the machine; mast00 becomes the sole user of `server-01.lic`.
- **`server-02.lic` moves to mast08** in `allocated.csv`, so an ordinary provisioning run licenses it with no manual step.
- **The asset directory now holds the 2026-2027 set** (LI06X02774-83, expiring 2027-07-01), replacing the 2025 set that was in it.
- **`assets/licenses/README.txt` is now tracked** and carries the operational half: where the real certificates live, that allocation is provider input for production units only, and that mastw is unlicensed deliberately and temporarily.

**mastw was the right host to unlicense** because it is the workshop machine rather than a production unit, and because it is not provisioned -- so nothing can re-grab a seat for it behind our backs, and the release stays done without needing a marker in `allocated.csv` to defend it. mast00 was ruled out: it is still in use.

**This is explicitly temporary.** If further subscriptions are bought, mastw gets one. mastw is also expected to join the fleet under a `MASTxx` unit name, at which point it takes a seat through `allocated.csv` like any other unit. Nobody should read the absent row as a decision that mastw must stay unlicensed -- the README says so, because a bare absence reads as an oversight and invites a well-meaning "fix".

**A seat is a file, and nothing enforces that.** The certificate is a signed text file whose fields are `Product`, `Customer`, `E-mail`, `Product Id`, `Subscription Id`, `Subscription Type`, `Expiry`, `Platform`, `Users`, `Connections`, `Virtual Desktops`, `Processors`, `Product Key`, `Subscription Key`. No hostname, no MAC, no fingerprint. `C:\ProgramData\NoMachine\var\` holds only `db`, `log`, `run`, `tmp`, `uninstall` -- no activation record anywhere -- and `server.cfg` has no licensing keys. So there is no deactivation step to perform and no vendor to notify: moving a seat is `Copy-Item` plus `Restart-Service nxservice -Force`. The one-installation-per-subscription limit is contractual, which is precisely why the mast00/mastw duplicate ran for seven weeks without a single warning.

**Two adjacent errors this cleaned up:**

- **The expired set was in the repo.** `Licenses 2026\files.zip` and the older `licenses\` folder on the mast-ns-control share use the same ten filenames, so a certificate restored from the wrong folder is indistinguishable by name. The 2025 set was restored on 2026-08-23 and provisioned onto mast06 and mast07 before the expiry dates were read. Replacing the assets changes the module's content hash, so an ordinary run now converges both units.
- **`allocated.csv` said mastw held `server-02`.** It never did. The record and the machines had disagreed since 2026-07-01.

**Rejected:**

- **Leaving the duplicate in place and giving mast08 `server-02` anyway.** Works technically -- nothing checks -- and was the tempting option because it requires touching no machine. Rejected because it would have left the fleet permanently one seat over its entitlement while `allocated.csv` claimed otherwise, and the only reason we found this at all was someone reading the certificates by hand.
- **Buying an eleventh subscription.** The correct answer if every host genuinely needs one, and not ours to spend. Reconsider when mastw joins the fleet as a unit, since that is the point at which eleven hosts really do need eleven seats.
- **Unlicensing mast00 or mast-ns-spec instead.** Both are in use.
- **Tracking the `.lic` files in git** so they cannot be lost again. They are purchased credentials; the repo has no encrypted store for that, and `data/`-style tracking would put license keys in every clone. The README now names the share to re-fetch from, which is the cheap half of the fix.

**Unsettled:**

- **What an unlicensed NoMachine actually does.** mastw's log shows `ERROR! Your NoMachine subscription is expired` alongside a session-level `WARNING!` while the service kept running, so it degrades rather than stopping dead -- but whether sessions still connect is a vendor question nobody has answered. If NoMachine is how anyone reaches mastw, that access may be gone; RDP and physical access are not affected.
- **mast05's certificate is unverified.** It should carry `server-08.lic` from the 2026-07-07 rollout, but it does not resolve by hostname from the office and has not been read.
- **The `.lic` files remain untracked and unignored**, which is the exact shape that let them be swept once already. Nothing prevents a repeat.
- **Renewal is a hand operation with no procedure.** The 2026 set was installed by two different methods a week apart -- by hand on the three unprovisioned hosts, by provisioning run on the units -- and the hand half is where the duplicate came from. Nothing schedules the 2027-07-01 renewal or checks that certificates on disk have not expired; the `nomachine` module installs a file and never looks at its `Expiry`.
