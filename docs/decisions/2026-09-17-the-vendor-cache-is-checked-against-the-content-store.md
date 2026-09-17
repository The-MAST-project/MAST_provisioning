---
decided: 2026-09-17
status: accepted
issue: MAST_provisioning#194
areas:
  - storage
  - reproducibility
  - failure reporting
---

# The vendor cache is checked against the content store, and the mirror lives in the repo

**Why:** five build inputs are not in this repo and cannot be casually re-acquired. They had a canonical copy on `mast-ns-control` and no way to tell whether the build host's copy still matched it. A backup nobody reads has its corruption discovered at restore time, which this repo has on record already: an LFS pointer outside the filter checked out as 132 bytes of text while `git lfs pull` exited 0, and nothing noticed.

Two things found on inspection, neither of them in the issue. The `MAST-vendor-mirror` task ran `C:\agent-worktrees\2026-09-10-transfer-executed-set\vendor-mirror.cmd` — a task folder the workspace contract tears down with `rm -rf` — and was registered `One Time Only`, so it had run exactly once on 2026-09-10 and had no next run. And its source list was hardcoded and had drifted from `server/data/vendor-inputs.json`: `nomachine-licenses` was declared but absent from the script, so four of five inputs were mirrored by the job and the fifth reached the store by hand, with the job exiting 0 having done what it was told.

**What:** `tools/vendor-mirror.sh` and `tools/vendor-verify.sh` live in the repo and run from the canonical clone; `docs/provisioning-server-setup.md` step 4d registers both. `server/prov/tests/test_vendor_inputs.py` asserts that each script's delimited source block matches `vendor-inputs.json` exactly, that the two scripts agree with each other, and that neither path contains `agent-worktrees`.

**The verify needs no checksum list, which is the part worth knowing.** #194 anticipated writing a `MANIFEST.sha256` and noted that #202 landing first would make the comparison trivial. It landed, and more completely than expected: measured 2026-09-17, **all 266 vendor files and 12.03 GiB are already blobs in the content-addressed store**, whose filename *is* the SHA-256. So the check is `sha256sum` locally, shape the result as the manifest `relay-store.py` already reads, and ask `want` which digests the store does not hold — a digest that comes back is a local file whose content is not what the canonical copy has. 266 files hash in ~35 s, so it runs daily; verifying by re-transfer would take 35–60 minutes at the measured 3.4–6 MB/s.

Provenance is **generated** from `vendor-inputs.json` by `tools/write-vendor-provenance.py` rather than written by hand, because the prose already exists there and a hand-maintained second copy is a second copy that goes stale. It deliberately carries no checksum, for the same reason the verify needs no manifest.

**A destructive mistake, recorded because the shape of it will recur.** The generator first emitted one directory per entry, `<name>/PROVENANCE.md`, and the mirror rsyncs that tree *into* `/Storage/mast-vendor/` over the bytes it describes. `full-frame.fits` is a **file** entry, so rsync replaced the 90 MB file on the canonical store with a directory containing its provenance, and the five subsequent attempts to sync the real file all failed with a directory in the way. Recovered completely: the content store still held the blob at `fd8618de…`, so relinking it restored the file byte-identical, with its original mtime and its link count back to 11. `provenance_path()` now branches on `kind`, a file entry gets a sibling `<name>.PROVENANCE.md`, and a test asserts a file entry never becomes a directory.

The lesson generalises past this bug: anything rsynced into a tree of real artifacts has to know which entries are files, and the content store is what made a destructive mistake on the canonical copy a five-second repair rather than a re-transfer over a 3.4 MB/s link.

**Only the verify is scheduled.** The mirror pushes this cache *to* the canonical store, so putting it on a cadence would let the cache overwrite the canonical copy every time it fired — and on a machine that already holds a file named `MAST-15GB-indexes-5202+5203-corrupt.img`, that is the mechanism by which rot would reach the good copy. A weekly mirror was in the first draft of this change and was wrong for exactly the reason the issue gives for the store existing. The mirror is an occasional deliberate act; the verify is the job whose only purpose is to notice, which is what belongs on a timer.

**Rejected:** *a `MANIFEST.sha256` beside the bytes*, which #194 proposed as a fallback — it is a second answer to a question the store already answers, and it would need to be kept in step. *Hand-written provenance*, for the same reason. *Driving the mirror from `mast-ns-control`*, which is not available: the site cannot initiate to the institute, so both jobs push from the build host.

**Unsettled:** the three legacy index images on the build host, 45 GiB in total, are **not** resolved here. The `-corrupt` twin is worthless and safe to delete, but `MAST-15GB-indexes-5202+5203.img` carries a **LastWriteTime of 2026-09-17 00:32** against a creation date of 2026-05-28 — something wrote to a file declared superseded and untouched since May, and until that is explained, deleting around it is premature. `not_vendor_inputs` also lists only the `.img`, not its `.bak` or the corrupt copy, so the guard test does not cover them.

**Implications:** re-registering the two tasks cannot happen until the canonical clone on the build host is updated — it sits at `9e5f136` (#182), many PRs stale, and does not yet carry these scripts. Until then the vendor store has no scheduled mirror at all, which is the state it has been in since 2026-09-10.
