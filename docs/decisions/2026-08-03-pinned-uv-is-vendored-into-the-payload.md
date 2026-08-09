---
decided: 2026-08-03
status: accepted
issue: MAST_provisioning#31
areas:
  - source-layout
  - providers
  - reproducibility
---

# The pinned uv is vendored into the payload, as a zip plus its checksum

**Why:** `mast-clone.ps1` builds the role venv with uv, and left to itself it
downloads the pinned release from the GitHub releases CDN **at provisioning
time**. That puts every unit's run at the mercy of GitHub reachability and
throughput from the observatory -- the same class of dependency the frozen
Cygwin package cache removed for astrometry (issue #20), and the same reason
the astrometry index seed is build-host-vendored.

**What:** `server/providers/mast/assets/uv-x86_64-pc-windows-msvc.zip` plus the
publisher's `.sha256` is committed via git-LFS and staged as a commandfile.
`provide-mast.ps1` verifies the checksum, extracts `uv.exe` to
`<Top>\.tools\uv.exe`, then asserts `uv --version` equals the `#!uv-version`
pin in the staged `mast-repos.tsv`. **No change to mast-clone was needed:** it
already prefers an existing `<Top>\.tools\uv.exe` over bootstrapping, so
vendoring is a drop-in.

**Rejected:**

- **Vendoring the extracted `uv.exe`** instead of the zip. Rejected on two counts:
  46 MB against 18 MB in git and in every payload, and shipping the publisher's
  `.sha256` beside the zip preserves the integrity check mast-clone's own bootstrap
  performs. A loose binary in the tree would have to be trusted rather than verified.
- **Taking the uv version as a parameter to `build/fetch-uv.ps1`.** Rejected so the
  vendored artifact and the version the scripts expect cannot be bumped independently
  -- the refresh tool reads the version from `tools/mast-repos.tsv`, the same pin
  mast-clone uses. The runtime assertion is what catches a tree where they disagree
  anyway.
- **Changing `mast-clone.ps1` to accept a pre-supplied uv.** Unnecessary: it already
  prefers an existing `<Top>\.tools\uv.exe` over bootstrapping, so vendoring needed no
  upstream change at all. Worth recording because the instinct is to modify the tool.
- **Letting a production build proceed without the asset.** Rejected -- a production
  build now requires it and fails loudly. `-TestMode` skips it, exactly as
  `cygwin/assets/astrometry.tgz` does, and mast-clone falls back to the CDN, which
  still works for a dev box.

**Unsettled:**

- **The asset is a git-LFS object in a repo with no remote**, so it lives only in
  `.git/lfs/` on the machines that have it. Whether the LFS objects are actually
  replicated anywhere is unverified, and it is the same unaddressed footing as the
  other build-host-vendored payloads.
- **Refreshing the vendored uv is a manual step** with a documented tool, and nothing
  reminds anyone to do it. The pin therefore ages silently.
- **Only the Windows x86-64 asset is vendored.** A prov host or unit on any other
  platform falls back to the CDN, which is the case the vendoring exists to avoid.
- **Verified end to end on labcomp2**, where a production `build-mast.ps1 -Modules mast`
  staged the zip and its checksum, and the checksum + extract + version-assert sequence
  produced `uv 0.11.33` matching the pin, at the path mast-clone probes. Not exercised
  on a unit at the observatory, which is the environment the change is for.

**Implications:** A unit's venv build no longer depends on GitHub being reachable from
the observatory at the moment it provisions.
