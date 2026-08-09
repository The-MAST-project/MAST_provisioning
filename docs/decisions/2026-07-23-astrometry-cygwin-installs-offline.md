---
decided: 2026-07-23
status: accepted
issue: MAST_provisioning#20
areas:
  - astrometry
  - providers
  - reproducibility
---

# Astrometry's cygwin installs offline from a frozen package cache, pinned to 3.6.9

**Why:** `provide-astrometry-dependencies.ps1` installed cygwin from the
**live** itefix mirror (`--site https://cygwin.itefix.net --upgrade-also`),
while the bundled fitsio wheel is **version-pinned** in its filename tag
(`cygwin_3_6_9`). pip derives the cygwin platform tag from the *running*
cygwin, so when the rolling mirror moved 3.6.9 -> 3.6.10 a fresh provision
installed 3.6.10 and pip rejected the wheel ("not a supported wheel on this
platform"), failing the module on any newly provisioned unit (issue #20).
Root cause: a pinned wheel coupled to an unpinned, live-mirror-tracking
cygwin.

**What:** Freeze the exact known-good package set and install fully offline.
The cache is **harvested once from a working unit** (mast01's own
`C:\cygwin64\var\cache\setup`, ~174 MB -- authoritative because it *is* what
the validated fleet installed) via the new `build/harvest-cygwin-cache.ps1`,
stored **build-host-vendored** at `C:\MAST\cygwin-pkg-cache` (like the
astrometry index seed -- binary, not in git), staged into the payload by
`build-mast.ps1` (warn under `-TestMode`, throw for production builds), and
installed with `setup-x86_64.exe --local-install --upgrade-also` (no `--site`
download). `--upgrade-also` is kept: the cygwin provider's tgz ships an older
base (3.6.5) and without the flag setup leaves it in place, so pip's platform
tag stays `cygwin_3_6_5` and the pinned wheel is still rejected; against the
frozen ini the flag is deterministic and reproduces the fleet's actual
2026-07-06 transaction. The proxy plumbing the online download needed
(`-ProxyMode`, `setup.rc` net-method, `--proxy`, the WinINet cert-revocation
toggle) is removed from this provider -- it was download-only. Module version
bumped to `0.97-deps-2`.

**Rejected:**

- **Re-pinning to cygwin 3.6.10 and rebuilding the fitsio wheel.** The
  follow-the-mirror fix, and rejected on cost against benefit: 3.6.10 is a patch
  bump with an identical `cygcfitsio-10` / `libpython3.9` ABI, so nothing used here
  changes, while it costs a wheel rebuild and a fleet re-provision to bring
  mast01-04 off the 3.6.9 they already run. Staying on 3.6.9 keeps the fleet
  uniform and the existing wheel valid.
- **Un-pinning the wheel** so it accepts whatever cygwin is present. Rejected as
  the wrong end of the coupling: the platform tag exists because the wheel really
  is ABI-specific, and a wheel that claims to work anywhere would fail later and
  less legibly than pip refusing it up front.
- **Keeping the live mirror and adding a version check** that fails when it moves.
  Rejected because it converts a silent breakage into a loud one without making a
  provision reproducible -- the module would still be unable to install on a unit
  the day the mirror moves, which is exactly the outage being fixed.
- **Building the frozen cache from the upstream mirror** rather than harvesting it
  from mast01. Rejected in favor of the harvest: the working unit's own cache *is*
  the set the validated fleet installed, which makes it authoritative in a way a
  reconstructed download is not.
- **Dropping `--upgrade-also` now that the install is local.** Measured and kept --
  without it, setup leaves the provider tgz's older 3.6.5 base in place and the
  platform tag becomes `cygwin_3_6_5`, so the pinned wheel is rejected for the
  opposite reason. Against a frozen ini the flag is deterministic.

**Unsettled:**

- **The coupling is locked, not removed.** The frozen cygwin version and the fitsio
  wheel tag now move together: refreshing the cache to a newer cygwin *requires*
  rebuilding the wheel in the same change. That constraint lives in `DEPENDENCIES.md`
  and in nothing that enforces it.
- **Each build host needs the one-time harvest**, and a host that has not had it
  produces a build that throws (production) or warns (`-TestMode`). Real units need
  no re-provision, since they already run 3.6.9.
- **The ~174 MB cache is build-host-vendored, not in git**, so its integrity and
  backup rest on the same unaddressed footing as the astrometry index seed.
- **Freezing forgoes upstream security updates** to the cygwin package set for as
  long as the pin holds, and nothing tracks how long that is.

**Implications:** The installed cygwin is deterministic regardless of what the live
mirror serves, and astrometry-deps now works on offline and bench units -- a gap
carried in the #8 backlog. Full plan: `docs/cygwin-freeze-plan.md`.
