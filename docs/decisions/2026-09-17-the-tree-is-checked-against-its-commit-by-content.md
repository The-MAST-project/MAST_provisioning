---
decided: 2026-09-17
status: accepted
issue: MAST_provisioning#216
areas:
  - reproducibility
  - failure reporting
  - storage
---

# The working tree is checked against its commit by content, and the store against its own names

Completes #216. The `.gitattributes` change that closed it removed the *cause* found on 2026-09-17; this is the detection that would have found it, and the next one.

**Why:** `BUILD_OK` reports a `payload_hash` beside a `git_sha`, which is a claim that the payload derives from that commit. Nothing established the claim. `git status` cannot: its stat cache skips the content comparison whenever a file's size and mtime match the index entry, so a tree diverges from its own commit and goes on reporting clean. Two trees at `dd4d16f` did exactly that and built payloads differing in 113 files.

The same class had already bitten once, differently. In #101 an LFS pointer outside the filter checked out as 132 bytes of text, `git lfs pull` exited 0, `git status` was clean, and the build staged the pointer as an installer. One bug, two hats: **on-disk bytes are not what the commit means, and nothing looks.**

**What:** `server/prov/tree_integrity.py` answers it for both populations, because they need different questions. An ordinary file must hash to the blob the commit records, read with `--no-filters` — the flag is load-bearing, since the clean filter is precisely what lets a CRLF working file "match" an LF blob. A git-LFS file cannot be compared that way at all: the commit holds only a pointer, so raw comparison would flag every correctly-smudged asset. The pointer verifies itself instead, carrying the real object's `oid sha256` and `size`, which is also what catches #101.

**Only invisible divergence counts.** Anything `git status` already reports is somebody's work in progress — visible, normal, not this bug — and failing on it would make the guard unusable within a day. The dangerous set is exactly what status does not report. The tests reproduce that state with `git update-index --assume-unchanged`, which is the same end condition: a file git will not look at.

The driver runs it once per run at preflight, not per unit — it is a property of the repository, and every unit in the run would otherwise build the same wrong payload. A divergence is **fatal**: a payload whose sources do not match its recorded provenance is attributable to nothing. A guard that cannot run logs `PREFLIGHT_TREE_UNVERIFIED` and allows the run, because an unusable answer is not a failing one.

`tools/relay-store.py fsck` re-hashes every blob and confirms it is still what its name says. A content-addressed store's filename *is* its checksum, which makes the property checkable — but nothing checked it, so it was an assumption, and every other guard compares something *against* that store (#194's vendor cache, #189's landed payload). If a blob rots they all agree with the rot. A corrupt blob is reported and left in place: deleting it would take out every hardlink into it across every host tree at once, and a bad byte is more recoverable than a missing file.

**It found a live instance on its first run.** Against the build host's canonical clone — a tree everyone including its author believed clean — one file diverged: `server/providers/nomachine/assets/licenses/allocated.csv`, CRLF on disk against LF in the commit, content otherwise identical, `git status` clean. The cause is this repository's own build: `Save-AllocCsv` writes a **tracked** file with `Export-Csv`, whose CRLF the clean filter then normalises away on read. Every build re-created it. `Save-AllocCsv` now writes LF.

**Rejected:** *`git update-index --refresh` then `git diff-index`.* The standard recipe, and it does not work here: it re-stats files whose stat has changed, while this failure is a file whose stat matches and whose content does not. It would also still run the clean filter, which is the blindness being removed. *Recording a source-tree hash in `build-manifest.json`* — proposed in the plan and dropped. It makes divergence *attributable* after the fact, which is worth much less once the guard makes it impossible to ship; it is another hash pass and another manifest field to keep in step, for a case that can no longer occur on the production path. *Failing on anything `git status` reports*, which would fail on every working edit.

**Unsettled:** `thorough` mode hashes LFS content and is not enabled by the driver. The default checks an LFS file for being a pointer and for its size, which catches both field failures; bit rot that preserves size is caught by `fsck` on the relay instead, where the bytes actually live. Nobody runs `fsck` on a schedule yet — it belongs on the same daily timer as `vendor-verify.sh`, and until it is there the store's self-verification is available rather than performed.

Existing task worktrees on the build host predate this and are still CRLF: one reports **377** divergences. That is correct — they genuinely do not match their commits — but it means a build from one now fails until it is re-checked-out. The failure names the repair.

**Implications:** measured on the Windows build host, 555 tracked files in **5.0 s** — after batching the LFS pointer reads through `git cat-file --batch`. One `cat-file` per path cost 229.6 s there against 3.2 s on a Mac, which is the kind of gap that turns a correct guard into one somebody disables.
