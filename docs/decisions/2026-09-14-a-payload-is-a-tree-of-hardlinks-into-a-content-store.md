---
decided: 2026-09-14
status: accepted
issue: MAST_provisioning#202
areas:
  - transfer
  - storage
  - orchestration
---

# A payload is a tree of hardlinks into a content-addressed store, not a delta against the last one

**Why:** #186 stopped sending 14.9 GB per unit by passing the vendor mirror as an rsync `--link-dest`, and that worked — 87% of a host tree hardlinked, a second host measured 199 bytes. What it did not cover is the **1,959,264,676 bytes** that are not vendor input: the wheelhouse, the cygwin package set, the MAST repo trees, the NoMachine and driver installers. Those moved in full on every build. Over a WAN measured at ~3.4 MB/s that is roughly ten minutes per build before a unit is touched.

The obvious extension was to chain `--link-dest` to the previous payload. It was rejected on a point that is about what the mechanism *models*, not about what it saves today. `--link-dest` deduplicates against a **named predecessor**, which assumes a linear history. The moment units sit on deliberately different stacks — one on a pinned build for experimentation, the rest current — "most recent" is an arbitrary neighbour rather than an ancestor, the saving degrades toward zero, and nothing reports that it has. A mechanism whose correctness depends on a lineage the fleet does not have is wrong before it is slow.

**What:** the relay keeps a content-addressed store. `tools/relay-store.py` runs on mast-ns-control, driven over ssh by `prov.relay`:

```
store/<aa>/<sha256>              one copy of each distinct blob
hosts/<host>/01-provisioning/    hardlinks into store; what SMB serves
```

`build-mast.ps1` writes `payload-manifest.json` beside the staging root — every staged path with its size and SHA-256, from the walk that was already hashing them (#203). The driver sends that manifest, asks `want` which digests the store lacks, rsyncs only those, and calls `assemble`, which builds the host tree as hardlinks and prunes whatever the manifest no longer names.

The manifest is written **beside** the staging root rather than inside it: it describes the payload, so it is not part of it. Inside, it would have to exclude itself from its own hash and would then travel to every unit for nothing.

**Measured.** Seeding the store from the trees already on the relay collapsed 1,895 names into 561 distinct blobs totalling 14.88 GB with **zero growth** in `du` — the existing trees became links into it. The first driver run through the store then synced mast07 in **5.5 s with `blobs_sent=1`**: 41,800 bytes, the freshly-written `build-manifest.json`, against 1,959,264,676 bytes for the same build the day before. Assembly reported `files=543 bytes=14877440807`, equal to what the unit's destination verification (#189) demands.

**Rejected:**

- **Chaining `--link-dest` across versions.** Above: models a lineage the fleet does not have.
- **Reusing `--link-dest` against the store.** Not possible even in principle. rsync matches candidates by relative **path**; a store keyed by hash has no path to match. The assembly had to be ours, and once it is, rsync's only job is moving blobs the store lacks.
- **Deltas between versions** (the first shape the idea took). A content store subsumes the *transfer* half of it: two payloads share exactly the bytes they share, in any order, with no base to keep or to reconstruct from. It does **not** yet deliver the *retention* half — see Unsettled.
- **A flat `store/`.** Sharded by the first two hex characters; a year of builds would otherwise put tens of thousands of entries in one directory for no benefit.
- **Making the store authoritative.** It is not. labcomp2 builds; the relay holds what was built. The store doubles as a mirror of the fragile, unbacked-up binaries on labcomp2, which is the second reason it exists, but the source of truth question (#194) is open and this decision does not settle it.

**Unsettled:**

- **Old versions are not retained, which was half the original ask.** `assemble` prunes a host tree to the manifest it was given, so only the *current* payload is named; an older build's blobs survive in the store just until `gc`, which frees anything with a link count of 1. Retaining version N-1 needs a second tree (`versions/<payload_hash>/`) holding the links — cheap, since the blobs are already there, but not built. Until then "every version back" is true only of the bytes, not of a payload you could serve.
- **`gc` is manual, and its refcount is broader than it reads.** A blob is live while *anything* names it, the vendor mirror included — so a seeded blob is never collected, whether or not a payload wants it. Nothing runs `gc` on a schedule and no retention policy is decided.
- **Nothing verifies the store against itself.** A blob whose content has drifted from its name would be assembled into a host tree silently; the check is cheap (`sha256` of each blob against its filename) and belongs to #194's cache-verify job.
- **Writing through a hardlink corrupts every tree that shares the inode.** Anything that edits a file in a host tree in place — rather than unlinking and replacing it — writes into the blob. Nothing in the pipeline does, and `relay-store.py`'s header says so, but it is a property of the layout rather than something enforced.
