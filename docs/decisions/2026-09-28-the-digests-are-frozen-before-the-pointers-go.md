---
decided: 2026-09-28
status: accepted
issue: MAST_provisioning#48
areas:
  - reproducibility
  - source-layout
---

# The digests are frozen before the pointers go, not with them

Phase 1b-iii of retiring git-LFS (#48), deliberately stopping short of the untracking itself.

**Why.** `server/data/assets.json` had two halves. The build-host rows were **declared** in `vendor-inputs.json`; the 162 LFS rows were **derived** from the pointers, which already record `oid sha256` and `size`. Deriving them was the right call while LFS was in place — it made the index impossible to get wrong, since it could not disagree with the thing it described.

It also means the index is only as durable as the pointers. `git rm --cached` the assets and `discover_lfs_paths()` returns an empty set, `_lfs_rows()` yields nothing, and the next regeneration writes a manifest with 256 rows instead of 418 — complete-looking, internally consistent, and missing 1.84 GiB. Nothing in the build would notice: `fetch-assets.sh` would report the cache complete against a manifest that no longer asks for those files, and a fresh build host would fetch 256 of 418 and fail later, somewhere else.

So the freeze cannot be part of the untracking commit. It has to precede it, while the pointers are still there to check the freeze against.

**What.** The 162 rows move into `vendor-inputs.json` as a `git-lfs` entry carrying each path, sha256 and size. The generator stops deriving anything; every row is declared. The source name stays `git-lfs` rather than becoming `retired-lfs`, which is not cosmetic: renaming would have rewritten 162 `source` fields and destroyed the check that makes this commit safe — **regenerate and `files[]` must be byte-identical**, 418 rows in and 418 rows out, which is what was measured.

`provenance: false` marks the entry as having no directory in the canonical store, and three consumers key off that one field rather than each carrying its own list: `write-vendor-provenance.py` skips it (a `git-lfs/` tree beside `mast-indexes/` would be invented), `vendor-mirror.sh` does not rsync it (those bytes are already blobs in the store), and the prefix rule does not apply to it (it spans every module and the client media, so it declares explicit paths instead of one root).

**The transitional guard is the point of the split.** While both the frozen digests and the pointers exist, `test_asset_manifest.py` checks every frozen row against the pointer it was taken from, and that every pointer still in the tree has a row. Corrupting one digest makes it fail, which was verified rather than assumed. These tests retire with the pointers at the untracking — they are the one moment this can be checked at all, and skipping the moment would mean trusting a transcription of 162 digests on inspection.

**What this does NOT do.** Nothing is untracked. `tree_integrity.py` keeps its LFS branch, because 162 pointers are still in the tree and that check — pointer never smudged, size or content mismatch — is a live guard over exactly those files until they go. Clone size is unchanged; the objects are still in `.git` and on GitHub.

**Why stop here.** The untracking would leave labcomp2's cache as the only copy of that 1.84 GiB, and `fetch-assets.sh` recovers from the content store on mast-ns-control, which is down with a suspected system-disk fault. The cache was confirmed complete first — 418 of 418 by checksum, which needs no network once nothing is missing — so the freeze is safe to land now and the untracking waits for the store to come back rather than proceeding beside it.

**Implications.** The untracking becomes what it should be: remove the repo copies, gitignore the paths, drop the LFS rules, retire `tree_integrity`'s LFS branch and these two transitional tests. No index surgery, because the index already stands on its own.
