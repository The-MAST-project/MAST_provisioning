---
decided: 2026-08-11
status: accepted
issue: MAST_provisioning#75
areas:
  - source-layout
  - reproducibility
  - drift
---

# mast-clone pins a revision, and records what actually landed

**Why:** moving the fleet off git submodules to sibling clones (MAST_unit#94) traded away exact-commit pinning and nothing replaced it. A submodule pins a **commit** by construction; a sibling clone pins whatever `mast-clone` is told to, and that was a **branch**. So a unit got whatever the branch head was at the moment *its* clone ran.

That is not hypothetical. During the 2026-08-11 fleet run, two upstream merges landed mid-run:

```
MAST_common           master   b4991791   2026-08-11T11:38:35Z
MAST_unit.2024-12-12  main     1cf92164   2026-08-11T11:39:01Z
```

leaving three units on two different `MAST_common` commits and two different `MAST_unit` commits, from runs an hour apart on the same provisioning payload. Every run reported success. Nothing in the logs or the manifests said they had diverged — establishing it took four SSH round trips.

**What:** an optional 5th `rev` column in `tools/mast-repos.tsv` — a tag (preferred) or SHA, empty meaning "track the branch". Optional so a 4-column manifest still parses and repos can be pinned one at a time.

Pin semantics, implemented identically in `tools/mast-clone.ps1` and `tools/mast-clone.sh` because they share the manifest:

- **Clone**: clone the *branch*, then `checkout --detach <rev>`. Cloning the branch first rather than `clone --branch <tag>` keeps the branch ref present, which both the `--branch` override and the missing-`__init__.py` diagnostic rely on.
- **Update**: `fetch --tags --force` then re-assert the rev. Deliberately **not** `merge --ff-only @{u}` — that is a branch operation and would defeat the pin. A pinned repo moves only when the pin moves.
- **Override**: a `--branch`/`-Branch` override for a folder **disables** its pin, logged loudly. A developer following a feature branch should not be silently overruled, and the log line is what stops that checkout being mistaken for the pinned one.

Alongside it, `<Top>/clone-manifest.json` records per repo the branch, the rev **as requested**, the `resolved_sha` that **actually landed**, and `head` (`"HEAD"` for a detached pin). Both halves matter: a tag can be force-moved upstream, and an unpinned repo resolves to whatever the head was at clone time. `Merge-MastInstalledManifest` folds it into `installed-manifest.json` as `repos`, so a unit can be asked what it is running.

Validated on mast03 (real git, PowerShell 5.1) against a throwaway origin with a tag one commit behind `master`:

```
pinned   : sha=2b2b8f7 head=HEAD   content=v1     <- the tag
floating : sha=d4b9f1f head=master content=v2
```

then advancing `master` and re-running with `-Update`:

```
pinned   : sha=2b2b8f7 head=HEAD   content=v1     <- did not move
floating : sha=036019e head=master content=v3     <- fast-forwarded
```

That asymmetry is the feature.

**Rejected:**

- **A separate lockfile.** More honest in one way — a lockfile is unambiguously generated — but it splits the source of truth in two, and `mast-repos.tsv` already carries pinned tool versions (`#!uv-version`) for exactly this reason. One file, one place to look.
- **A local branch at the pinned rev instead of detached HEAD.** Friendlier to a developer who then commits, which does happen on the bench. Rejected because a branch sitting at a pinned rev invites a commit that then *looks* like it is on `master` when it is not; detached is honest about what it is, and the `--branch` override exists for the bench case.
- **Pinning by SHA only.** Unambiguous and needs no upstream cooperation, and neither `MAST_common` nor `MAST_unit` tags releases today. Both forms work — `git checkout` does not care — so the column takes either; tags are documented as preferred because they read as intent in the manifest, and the recorded `resolved_sha` is what makes a force-moved tag detectable.
- **Keeping `-Update` as a fast-forward for pinned repos too.** It would make the pin advisory, which is the bug.
- **Recomputing the provenance in the merge function** rather than carrying the sidecar through. That would make the manifest a second, independently-derived opinion about what is checked out; the sidecar is the clone step's own report and should be recorded as such.
- **Reading the sidecar inside `Merge-MastInstalledManifest`.** Keeps the merge a pure function over its inputs, and means a malformed sidecar degrades to "no `repos` key" rather than failing the manifest write — which is the last thing standing between a good run and a unit that cannot say what it installed.

**Unsettled:**

- **Nothing is pinned yet.** The column ships empty on every row, so this change is a behavioural no-op until a `rev` is set. That is deliberate: pinning is a separate, reviewable commit, and choosing *what* to pin to is #24's territory.
- **The `.sh` half is unexercised.** `bash -n` passes and the logic is a line-for-line twin of the `.ps1`, but macOS ships bash 3.2 (no associative arrays, which the script requires) and no bash 4+ was available, so the end-to-end pin test ran only on Windows. The Linux control/gui path is untested.
- **A moved tag is recorded, not refused.** `fetch --tags --force` plus a re-checkout means a force-moved tag silently moves the fleet on the next run; only the changed `resolved_sha` reveals it. Refusing to move, or warning on a changed resolution, would be stricter — no field case yet to say which is wanted.
- **`fleet-drift-report.py` does not read `repos`.** The data is now in the manifest but nothing compares it across units, which is the thing that would have caught the 08-11 divergence automatically rather than on inspection.
- **The `head` field is redundant with `rev`** in every case except a hand-detached checkout. Kept because it is what makes "this unit is not on the branch you think" readable without inference.
