---
decided: 2026-09-27
status: accepted
issue: MAST_provisioning#48
areas:
  - storage
  - reproducibility
  - source-layout
---

# One asset store, one cache, one way to resolve it

Phase 1b of retiring git-LFS (#48, open since 2026-08-03), and the consolidation that issue actually asked for: *one versioned, backed-up asset store that every vendored binary goes through, whatever its size.*

**Why.** The plan for retiring LFS assumed the assets could become gitignored files where they already sit and that `build-mast.ps1` would need no change, because the paths do not move. That is wrong, and the reason is `workspace.sh`: builds run from **git worktrees**, and a fresh worktree holds no gitignored file. Every task folder would need its own copy, or every build would resolve nothing.

The five inputs that were *never* in git already solved that — `mast-indexes`, `ps3-catalog`, `cygwin-pkg-cache`, `full-frame.fits` and the NoMachine seats live outside any clone, machine-wide. But solving it five separate times is what the state actually was. There were two of everything:

| | LFS-held assets | build-host inputs |
| --- | --- | --- |
| index | `server/data/provider-assets.json` | `server/data/vendor-inputs.json` |
| canonical copy | the content-addressed store | `/Storage/mast-vendor`, an rsync tree |
| cache on the build host | — | four directories under `C:\MAST\` |
| tooling | — | `vendor-mirror.sh` push, `vendor-verify.sh` daily |
| sites in the build | one commandfile loop | five bespoke blocks, each with its own warning |

Seven places the build reads an asset from, two indexes describing the same kind of thing, and two answers to "where is the canonical copy". Adding a sixth cache for the ex-LFS binaries would have made it eight and three.

**What.** Every file a payload needs that the build does not author is one row in **`server/data/assets.json`** — 418 rows, 13.87 GiB — keyed by the repo-relative path it *would* have if it were tracked. The four cacheable build-host inputs acquire notional ones (`server/providers/imdisk/assets/mast-indexes/…`, `…/planewave/assets/Setup_PlateSolve3_Catalog.exe`, and so on), so the cache mirrors the repo tree and there is one rule: **an asset lives at `server/providers/<module>/assets/…`, in the repo or in the cache.**

The index has two halves and the split is deliberate. LFS rows are **derived** from the pointers, which already record `oid sha256` and `size` — so retiring LFS is mechanical rather than a transcription exercise, and the two cannot disagree while both exist. Build-host rows are **declared** in `vendor-inputs.json`, because nothing in the repo can derive a file the repo does not contain. That file is now an *input* to the generator rather than a surface anyone reads; `assets.json` is what the build, the fetch and the verify all read. Their digests were not hashed by hand: all 266 vendor files were already hardlinked into the content store, so each one's sha256 was readable off its blob's name by inode.

`Resolve-MastCachedFile` carries the rule and nothing else — two candidate paths in, the repo one if it exists, else the cache one, else the repo one again so a "missing" message names the location a person expects. It takes both paths already formed rather than deriving them, because the callers have genuinely different layouts: a provider asset is keyed off `<top>\server\providers`, the bootstrap media off `<top>`. `Resolve-MastAssetSource` and `Get-MastAssetTreeEntries` express the per-file and per-directory cases in terms of it, and the seven read sites collapse to those two plus the primitive.

Directory-shaped assets resolve **per file, not per tree**, because some of those directories are mixed: `assets/sxs/` holds three vendored `.cab` files beside a `README.md` and a `fetch-from-iso.ps1` that are ordinary tracked code, and `nomachine/assets/licenses/` holds an `allocated.csv` the build itself writes. "Which root does this directory come from" has no answer; "which root does this file come from" does. Staging then links or copies each entry, which also means the 9.9 GB index seed arrives as 96 hardlinks instead of one junction — and reparse points were the trap that left 9.9 GB outside the payload hash in #203.

**Precedence is repo-wins, and that is the point rather than a detail.** It makes landing this a **no-op**: every LFS asset is still tracked, so every one still resolves from the repo, and the behavior change happens in a later commit that removes those copies. The risky step and the change of behavior are not in the same PR.

**Two things stop being quiet.** Four of the five build-host inputs only `Write-Warning`ed when absent, so a payload could build clean and fail two hours later on the unit; they throw now, with `-TestMode` as the dev escape. And `Get-ModuleContentHash` skipped a missing commandfile entirely — so a payload built without a 2 GB installer hashed *identically* to one built with it, and a unit holding the wrong payload looked up to date. It records the absence instead, so the two differ.

**Rejected.** *Gitignored files in the repo tree*, for the worktree reason above — the plan this replaces. *A cache keyed by hash rather than by path*, which the store already is; the build opens `assets/Setup_PWI_4.1.6_Final.exe` by name, so the cache mirrors repo-relative paths and the manifest is the only mapping. *Cache-wins precedence*, which would have put the resolution change and the untracking on the same risk. *Folding the NoMachine seats into the cache*: they are issued certificates sourced from the gitignored `vault/`, and `Assert-MastNoNoMachineCertsInAssets` exists precisely to keep them out of `assets/` — they stay a recorded, backed-up, uncached source, and a test asserts no uncached source reaches an asset row.

**Unsettled.** `/Storage/mast-vendor` is now a redundant named view: all 266 of its files are hardlinked into the content store, so it holds no bytes of its own and no information `assets.json` does not. Retiring it is the obvious next step and is deliberately not in this change — it consumes nothing, and deleting a 14 GB-looking tree on the canonical store is its own act with its own verification. The one thing that must survive it is `nomachine-licenses`, which is genuinely only there.

A build host that has never fetched gets nothing from `git clone` alone and must run `fetch-assets.sh` — measured 3m12s for the 1.84 GiB of ex-LFS assets, and the full 13.87 GiB is the same path. That is the honest answer to #48's *"whether the provisioning server should be able to build with no network at all"*: the ability is unchanged, the first-run speed is not. Re-running over a complete cache costs 24s to hash all 13.87 GiB, which is why the daily job runs the fetch rather than a report-only verify — noticing rot and fixing it are the same pass, and `vendor-verify.sh` is retired.

**Implications.** The untracking (1b-ii) becomes small and reviewable — remove the repo copies, gitignore the paths, drop the LFS rules — because the machinery is already in place and already exercised. `client/assets/npcap-1.88.exe` is indexed and cached and the ISO builder reads through the cache, so it will not be the one thing the untracking breaks.
