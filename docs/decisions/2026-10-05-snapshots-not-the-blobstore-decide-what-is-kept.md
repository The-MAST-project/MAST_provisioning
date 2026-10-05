---
decided: 2026-10-05
status: accepted
issue: MAST_provisioning#48
areas:
  - storage
  - reproducibility
  - os patching
  - bootstrap
---

# Snapshots, not the blobstore, decide which files are kept

**Why:** the relay's content-addressed store had picked up five names (content store, content-addressed store, vendor store, asset store, relay store), and its retention rule was an accident. `gc` in `tools/relay-store.py` deletes any blob whose link count has fallen to 1, so a blob stayed alive only while some other tree happened to link it. On 2026-10-05 that was each unit's current payload under `hosts/<unit>/`, plus `/Storage/mast-vendor` and `mast-provisioning/vendor-view`, which the 2026-09-27 record (`2026-09-27-one-asset-store-one-cache-one-way-to-resolve-it`) had already called redundant. Three gaps followed from that, all checked on mast-ns-control that day:

- A unit's host tree holds only its *current* payload. The 2026-09-14 record (`2026-09-14-a-payload-is-a-tree-of-hardlinks-into-a-content-store`) said as much: older versions' bytes survived only until the next `gc`, and `versions/<payload_hash>/` was not built.
- Two assets were held by nothing but the store's own name: `client/assets/npcap-1.88.exe`, which goes on the bootstrap medium rather than into a payload, and `AscomDeveloper662.4294.NewCertificate.exe`, which no payload had staged since 2026-05-04. The next `gc` would have deleted both.
- The OS baseline `19044-2026-09`'s two `.msu` files were not in the store at all, nor in labcomp2's asset cache, nor in any task folder found. The Update Catalog drops superseded updates (KB5039211 already resolves to nothing), so a committed baseline's files had nowhere they were reliably kept.

The design discussed on 2026-10-04 added a `retain/` tree mirroring `assets.json`, whose only job was to hold a link. It was rejected in discussion as artificial: it held a link without naming anything that had been, or would be, shipped.

**What:** the store becomes the **blobstore** (`blobstore/<aa>/<sha256>`, `tools/blobstore.py`, `tools/blobstore-fsck.sh`, scheduled as `MAST-blobstore-fsck`). It only stores blobs. What is kept is a **snapshot**: an immutable tree of hardlinks per payload or baseline, `<kind>/<id>/`, with the manifest it was built from beside it as `<kind>/<id>.json`. The kinds are fixed by `SnapshotKind`:

- **`provisioning-payload/<payload_hash>/`**: `cmd_assemble` snapshots each host's payload as it assembles the host tree. So every payload a unit has been served stays restorable, and units on one payload share one snapshot.
- **`windows-os-baseline/<baseline-id>/`**: `python -m prov.os_updates ... snapshot`, run after a baseline's JSON is committed. It hashes each file in the asset cache against the manifest before sending anything.
- **`bootstrap-payload/<hash>/`**: `python -m prov.bootstrap_payload ... snapshot`. The bootstrap payload is newly declared once, in `client/bootstrap-payload.json`: seven files that had been described three ways (a README step naming three, the ISO builder staging seven, and whatever an operator copied). `prov.bootstrap_payload ... stage --out` copies them onto a stick, and its hash is its identity.

`snapshot()` builds beside its final name and renames into place. It treats the same id with the same content as a no-op, and refuses the same id with different content. `prov.relay`'s four steps (ship the script, `want`, upload, final command) moved into `_sync`, shared by `sync_payload` and the new `sync_snapshot`. `gc` is unchanged and still manual. Nothing prunes snapshots yet.

`/Storage/mast-vendor`, `vendor-view`, `tools/vendor-mirror.sh` and `tools/write-vendor-provenance.py` were retired. Where each build-host input came from stays in `server/data/vendor-inputs.json` (`origin`, `reacquire`), which drops the `kind` and `provenance` fields only those tools read. The NoMachine seats were never blobs. Their canonical copies were found on 2026-10-05 in `vault\` on labcomp2 and as `Licenses 2026/files.zip` under `/Storage/mast-share/Downloads/NoMachine/`, matching the `mast-vendor` copies byte for byte.

**Rejected:**
- *A `retain/` tree mirroring `assets.json`.* It held links for whatever the repo's manifest said today, not for anything shipped.
- *Freeing a blob automatically when its last tree goes*, by dropping the hash name. The hash name is what makes "which digests are missing?" one lookup and what lets `fsck` check a blob against its own name. It also kept the undo window that, on 2026-09-17, let a `full-frame.fits` overwritten by rsync be relinked byte for byte.
- *Freeing inside `assemble` when a pruned path's blob falls to one link.* That gives up the same undo window and races a concurrent build linking the blob back in.
- *`hosts/<unit>` as a symlink to its snapshot.* Samba would have to follow links out of the share (`wide links`), which loosens it for every path. Host trees stay plain link trees.

**Unsettled:**
- **No pruning.** Snapshots accumulate. That was deliberate for now, since versions share most blobs, but the policy (keep every version a unit still runs, plus the last N) is not decided or built.
- **A new asset has one copy until its first build.** It reaches the blobstore with the first payload sync that stages it. Before that it is only in labcomp2's asset cache, and this record does not close that window.
- **The ISO builder still has its own list.** `vm/build-autounattend-iso.ps1` stages the bootstrap files itself. `test_the_iso_builder_stages_every_file_of_the_payload` only checks that every listed name appears in the script.
- **Existing host trees had no snapshot when this landed.** They need a one-off `snapshot --kind provisioning-payload` from each `hosts/<unit>/payload-manifest.json` before `mast-vendor` and `vendor-view` are deleted. Until then those trees are their payloads' only holders.

**Implications:** `gc` is safe exactly when every payload or baseline that should outlive its current use has a snapshot. The git-LFS untracking (#48) can follow once the files are in both the blobstore and labcomp2's asset cache. Editing `provide-ascom.ps1` here, to drop the dead installer's name, changes the ascom module's hash, so units carrying it see one drift run.
