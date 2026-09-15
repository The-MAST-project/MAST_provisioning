---
decided: 2026-09-15
status: accepted
issue: MAST_provisioning#205
areas:
  - drift
  - providers
  - reproducibility
---

# The staging tree is hashed once, and both consumers read the resulting list

Follow-up to the 2026-09-14 entry "The build walks the staging tree once", which unified the *enumeration* and believed it had unified the hashing. It had not.

**Why:** that record claimed `Get-MastPayloadManifest` "gets its per-file SHA-256 free from the loop that was already hashing every file and discarding the value into the rolling digest." That describes a design nobody built. Both functions called `Get-MastStagedFiles` and then ran their own `Get-FileHash` loop, so every build made two full SHA-256 passes over 14.88 GB. Measured on labcomp2 building `mast03`: **41.2 s and 41.1 s** across two runs.

The cost is real but the more interesting part is why it survived review — the comment asserting the optimization sat directly above the code that did not implement it, so reading the function confirmed the claim.

**What:** `Get-MastStagedFileHashes` in `build/build-manifest-lib.ps1` is now the only thing that reads payload bytes. It returns `path` / `size` / `sha256` for every staged file and excludes nothing. `Get-PayloadHash` takes that list as `-Entries` instead of a `-StagingDir` and folds `"<path>:<sha256>\n"` into the rolling digest without touching a file; `Get-MastPayloadManifest` takes the same list plus the staging directory. `build-mast.ps1` calls the pass once and hands the result to both.

The same two builds after the change: **25.4 s and 25.6 s** — 15.6 s per build, about 38%, paid once per unit per run.

**The ordering that makes this less trivial than it sounds.** The two consumers see different file sets, and the difference is the whole of #203. `payload_hash` goes *into* `build-manifest.json`, so it is computed before that file exists and must exclude it; the payload manifest is written *after* and must include it, because the unit installs from it — omitting it assembled a 542-file tree against a 543-file payload and failed mast07's destination check with `short_transfer`. A single pass placed early therefore cannot produce the manifest's 543rd entry, which is the gap in the fix as #205 originally proposed it. So `Get-MastPayloadManifest` re-derives that one entry from disk: it drops whatever the pass captured for `build-manifest.json` — on a rebuild into an existing staging directory that is the *previous* build's copy — hashes the file that is there now, and throws if it is absent rather than returning a manifest one file short. One extra hash of a few kilobytes replaces a 14.88 GB pass.

Both exclusion rules stay written at their own call sites, named through one `${script:MastBuildManifestName}`. Pushing either into the shared pass is precisely how the two rules became one in #203.

**Rejected:** *having `Get-PayloadHash` call `Get-MastPayloadManifest`*, the shape #205 proposed. It inverts the dependency so the aggregate hash depends on the manifest, which cannot be assembled until after the hash is written into `build-manifest.json`. *Excluding `build-manifest.json` inside the single pass* would have removed the need to re-derive the entry, at the price of putting one consumer's rule in shared code — the #203 mechanism exactly.

**Unsettled:** `Sort-Object` is culture-aware, and the manifest re-sorts after appending its entry. For the ASCII paths the staging tree actually contains this agrees with the pass's own ordering, and `payload_hash` is built from the pass's order rather than the re-sorted one, so the digest cannot be affected. A staged filename that sorted differently under another culture would still reorder the manifest's `files` list; nothing depends on that list's order today.

**Implications:** `payload_hash` is unchanged — verified two ways before the refactor landed. A fixture tree in `server/tests/build-manifest-lib.Tests.ps1` is pinned to `d0d316cae32431b1fb4486adeea159822d5e16ff8fe44c2b5e91e42c50642562`, computed outside PowerShell from the specification rather than captured from the code, so a before/after comparison cannot pass by both sides moving together. And the real `mast03` build emitted `73efb18a558df31c64cca9938005df04453bb822aa91e7eb1689718c3e43ced7` on all four timed runs, matching the value the fleet recorded that morning. Had it moved, every unit would have read as drifted for the second time in two days — for a change that is purely about speed.
