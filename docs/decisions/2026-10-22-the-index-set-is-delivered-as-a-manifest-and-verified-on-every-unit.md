---
decided: 2026-10-22
status: accepted
issue: MAST_provisioning#254
areas:
  - storage
  - providers
---

# The index set is delivered to each unit as a manifest, and every unit is kept identical to it

**Why:** provisioning's index fileset is the canonical one, and every provisioned unit must hold it identically; mast00 and mastw are exempt (team decision, 2026-10-22). `server/data/assets.json` declares it (96 files, series 5202 and 5203), but nothing on a unit said which set it was given: the imdisk `verify` checked only that `imdisk.exe` existed, and the runtime checks carried hand-written guesses (the supervisor expected 5206 x 47, MAST_supervision#21).

**What:**

- `build-mast.ps1` derives the set from `assets.json` (`Get-MastDeclaredIndexSet`), fails the build when the staged seed differs from it by name or size (`-TestMode` warns), and stages it as `mast-indexes.json`, claimed by imdisk. The file is generated, never committed: `assets.json` stays the only place the set is written.
- The manifest's SHA-256 goes on the imdisk command line (`-IndexSetDigest`), as `-MinMemoryGB` does. Command strings are part of the module hash, so a changed set re-runs imdisk on every unit. A file only in the staging root would move the payload hash and not the module's, and the new set could reach no unit.
- `provide-imdisk.ps1` checks the staged file against that digest and the staged seed against the set before it changes anything, then installs the set as `C:\MAST\state\mast-indexes.json`. After mounting, a `D:\mast-indexes` that differs is first remounted from the image (under `-t vm` the RAM overlay can be what differs), and only an image that still differs is rebuilt from the seed. The detach is forced (`-D`), as the restart task's is.
- `verify-imdisk.ps1` replaces the inline verify: `imdisk.exe` present, and `D:\mast-indexes` equal to the installed manifest.
- The comparison lives once, in `server/providers/imdisk/mast-index-manifest-lib.ps1`, dot-sourced by the build, the provider and verify.

**Implications:**

- The exemption is the absence of `mast-indexes.json`. mast00 and mastw are left out of fleet runs by the registry's `excluded` field, but a run that names one with `--only-hosts` gives it a manifest, and then its image is converged like any unit's.
- A rebuild wipes `D:`. Provisioning removes the MAST services first; anything else holding `D:` (an app run by hand, ps3cli) loses it, and the provider log says so.
- Names and sizes only: hashing about 10 GB on every run is not affordable. A same-sized corrupted file is not caught.

**Rejected:**

- *Commit the manifest beside the provider, with a test that it matches `assets.json`.* A second copy in the repo, kept equal by a test, where a generated file keeps one.
- *Fail and report on a mismatch instead of converging.* Every provisioned unit is meant to hold the set, so the provider makes it so.
