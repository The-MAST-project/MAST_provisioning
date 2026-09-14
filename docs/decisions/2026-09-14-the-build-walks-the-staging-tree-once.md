---
decided: 2026-09-14
status: accepted
issue: MAST_provisioning#203
areas:
  - build
  - transfer
---

# The build walks the staging tree once, and that walk descends reparse points

**Why:** `Get-ChildItem -Recurse` does not descend reparse points. `build-mast.ps1` stages `mast-indexes` and `cygwin-pkg-cache` as directory junctions when the build runs elevated, so `Get-PayloadHash` — which enumerated that way — covered **290 of 543 files and 3.84 of 14.88 GB**. The 9.9 GB astrometry index seed sat outside the "has anything changed at all?" gate entirely: a re-seeded index moved no hash, the driver logged the unit `already_current`, and "current" stopped meaning anything about the larger half of the payload.

This is the third defect from the same trap. `prov/staging_size.py` had it (progress ran past 100% because `bytes_total` undercounted what robocopy moved through the junctions) and `Get-MastDirectorySize` in `mast-pull-staging.ps1` had it. Each was fixed where it was found, which is why there was a third.

**What:** one enumeration, `Get-MastStagedFiles`, in `build-manifest-lib.ps1`. It descends reparse points, guards cycles by resolved real path (a junction pointing at an ancestor would otherwise recurse forever), and returns lexical order by relative path so the rolling hash is deterministic across build hosts. `Get-PayloadHash` consumes it, and so does the new `Get-MastPayloadManifest` (#202), which gets its per-file SHA-256 free from the loop that was already hashing every file and discarding the value into the rolling digest.

**The payload hash changed for an unchanged source tree**, which is the expected and necessary consequence: the new hash covers 11 GB the old one did not. A real build on labcomp2 reported `Wrote payload-manifest.json (542 files)` where the old walk saw 290, and a new `payload_hash`. Every unit reads as drifted once, and that reading is the correct one.

**Two exclusions that are not the same exclusion.** `Get-PayloadHash` skips `build-manifest.json` because it runs *before* that file is written — it is generating it. `Get-MastPayloadManifest` runs *after*, and `build-manifest.json` is part of the payload: the unit reads it to record what it installed. Carrying the hash's exclusion into the manifest assembled a 542-file tree against a 543-file payload, and mast07's destination verification (#189) failed it `short_transfer ... landed_files=542`. The manifest excludes nothing.

**Rejected:**

- **Fixing `Get-PayloadHash` in place and leaving the other two walks alone.** That is what produced three copies. The walk is now shared, and `staging_size.py` documents in its own header that it is the Python side of the same requirement.
- **Not staging the junctions.** They exist so a 9.9 GB index seed and a cygwin package cache are not copied into every host's staging tree. Removing them to make enumeration easy would cost far more than it saved.
- **Suppressing the hash change** (excluding the junction contents so old hashes stay valid). The old hashes were wrong; preserving them preserves the defect.
