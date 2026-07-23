# #20 fix — freeze the cygwin package cache (offline, deterministic)

Branch: `eli/cygwin-freeze` (off `eli/provisioning-v3`). Fixes
The-MAST-project/MAST_provisioning#20. Separate from the #22 per-module-tracking
epic.

## Problem (recap)

`provide-astrometry-dependencies.ps1` installs cygwin via
`setup-x86_64.exe --site https://cygwin.itefix.net --upgrade-also …` — the
**live** mirror, upgrading to `curr`. The bundled fitsio wheel is version-pinned:
`fitsio-1.2.6-cp39-cp39-cygwin_3_6_9_x86_64.whl`. The mirror moved
**3.6.9 → 3.6.10**, so a fresh provision now installs 3.6.10, pip's platform tag
becomes `cygwin_3_6_10_x86_64`, and the 3.6.9 wheel is rejected ("not a supported
wheel on this platform"). Root cause: a **pinned wheel vs. an unpinned,
live-mirror-tracking cygwin**.

## Fix (locked decisions)

Freeze the exact cygwin 3.6.9-era package set as a **build-host-vendored offline
cache** and install it **fully offline** — the installed cygwin is then
deterministic and matches the wheel, with no live-mirror dependency.

- **Version: cygwin 3.6.9.** Matches the existing wheel (no rebuild); keeps the
  fleet uniform and known-good (mast01–04 already run 3.6.9). A cygwin *patch*
  bump to 3.6.10 buys nothing we use (identical `cygcfitsio-10` / `libpython3.9`
  ABI) and would cost a manual wheel rebuild + fleet re-provision + re-validation
  — deferred to a future change with a real driver. See #20 discussion.
- **Cache source: harvest from mast01.** Its `C:\cygwin64\var\cache\setup` is
  verified 174 MB, containing `cygwin-3.6.9-1-x86_64.tar.xz` + the full dependency
  closure + `setup.ini` — authoritative, because it *is* what the working units
  installed.
- **Storage: build-host-vendored (NOT git-tracked).** Mirrors the astrometry
  index seed (`C:\MAST\mast-indexes`), the NoMachine licenses vault, and the
  PlateSolve3 catalog — the repo stays lean; the cache is staged into the payload
  at build time.
- **Install: fully offline** (`setup-x86_64.exe --local-install
  --upgrade-also`) — no `--site` download, so there is no reintroduced drift
  surface. `--upgrade-also` stays: the cygwin tgz base is older (3.6.5) and
  must be lifted to the frozen 3.6.9; against the frozen ini the flag is
  deterministic (found on first validation, 2026-07-23).

## Steps

### 1. Harvest the frozen cache (one-time, build host)

- Copy mast01's `C:\cygwin64\var\cache\setup` — the whole
  `https%3a…itefix…\x86_64\…` tree + `setup.ini` (174 MB) — to a fixed build-host
  vendor path, `C:\MAST\cygwin-pkg-cache\` (mirrors `C:\MAST\mast-indexes`).
- Add `build/harvest-cygwin-cache.ps1` (pull from a working unit over SSH/SMB)
  and a short README, mirroring `build/extract-index-seed.ps1` for the index —
  the populate is a documented one-time step, not part of every build.

### 2. Stage the cache in `build/build-mast.ps1`

- Add a vendoring block modeled on the astrometry-index seed: set
  `${cygCacheSrc} = 'C:\MAST\cygwin-pkg-cache'`; if present, `New-LinkOrCopy`
  (or `Copy-Item -Recurse`) it into `${staging}\cygwin-pkg-cache\`; if missing,
  **warn under `-TestMode` / throw for a production build** with a "run
  `build/harvest-cygwin-cache.ps1` once" message (same posture as the index seed
  / SxS / PS3 catalog).
- It is **not** a `module.json` commandfile (it is build-host-vendored, not in
  the provider dir) — staged by this dedicated block, exactly like `mast-indexes`.

### 3. Switch the provider to offline (`provide-astrometry-dependencies.ps1`)

- Point `--local-package-dir` at the **staged** cache (resolved from
  `${AssetsRoot}` → `…\cygwin-pkg-cache`), add **`--local-install`**, keep
  `--packages <same set>`. Pass the original `--site https://cygwin.itefix.net`
  value only so setup selects the matching cache subfolder — with
  `--local-install` no download occurs (verify on first run).
- **Keep `--upgrade-also`** (needed to lift the tgz's 3.6.5 base to the frozen
  3.6.9; deterministic against the frozen ini). Make the proxy `setup.rc`
  write + the WinINet
  cert-revocation-disable block conditional/removed (both are online-download-only
  concerns).
- Net: setup installs exactly the frozen 3.6.9 set → `uname -r` = 3.6.9 → pip
  accepts the `cygwin_3_6_9` wheel → the module passes.

### 4. Verify + validate

- The provider already asserts the runtime DLLs and `import fitsio`, and
  `verify-astrometry-dependencies.ps1` checks the required cyg\* DLLs. Run the
  full VM cycle from post-prepare: `astrometry-dependencies` +
  `astrometry-verify` flip **green**, clearing the #20 red (leaving only
  `mast-validation`, which needs the ROI limit-frame merge — out of scope).

### 5. Docs + the coupling rule

- `DECISIONS.md` entry: offline-frozen-cache over the live mirror; the drift root
  cause; why 3.6.9 not 3.6.10.
- README at the vendor path / provider stating the **locked coupling**: the
  frozen cygwin version (`3.6.9-1`) and the fitsio wheel tag move together —
  **refreshing the cache to a newer cygwin REQUIRES rebuilding the wheel in the
  same change**.
- Update `autonomous-provisioning-requirements.md` if it references the astrometry
  install path; update / close #20 on validation.

## Impact / migration

- Real units mast01–04 already run 3.6.9 → **no re-provision needed** for
  correctness; a future re-provision reinstalls the frozen 3.6.9 set
  (idempotent). Only the dev VM had transiently pulled 3.6.10.
- Fresh/future units get deterministic 3.6.9 **offline** — which also fixes
  astrometry-deps for bench / offline-bootstrap units that have no internet (an
  #8 gap).

## Out of scope

- fitsio wheel rebuild / moving to a newer cygwin (#20 "option 2") — deferred to
  a future change with a real driver.
- `mast-validation` `RoiConfig.fiber_x` — needs the ROI limit-frame merge.
