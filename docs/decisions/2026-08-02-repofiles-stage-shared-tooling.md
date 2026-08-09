---
decided: 2026-08-02
status: accepted
issue: MAST_provisioning#31
areas:
  - providers
  - source-layout
  - drift
---

# `repofiles`: a module may stage shared tooling from the repo top, by leaf name

**Why:** The `mast` module is handing its cloning to `tools/mast-clone.ps1`
(#31), a script deliberately shared with the control host and dev boxes -- the
single source of truth the adoption exists to gain. But the staging pass
resolves a `commandfiles` entry as `Join-Path $providersRoot $module $cmdfile`
and mirrors that relative path into staging, so the two obvious ways to get the
script into the payload are both wrong: copying it into
`server/providers/mast/` at build time forks the shared file, and a
`../../tools/mast-clone.ps1` entry resolves correctly on the source side but
writes **outside** the staging root on the destination side.

**What:** `module.json` gains an optional **`repofiles`** array -- paths relative
to the **repo top**, staged to the staging root **by leaf name** (the flattening
`assets/*` already gets, so the module's `command` invokes them as
`.\mast-clone.ps1`; the unit-side executor runs every command with the staging
root as its working directory, so a nested path would not be found).
Resolution and containment live in the new dot-sourceable
`build/build-staging-lib.ps1` (`Resolve-MastRepoFile`,
`Get-MastRepoFileStagingPath`, `Get-MastModuleRepoFiles`) so Pester can exercise
them without running a build, mirroring how `build-manifest-lib.ps1` was split
out. An entry that is absolute, contains a `..` segment, resolves outside the
repo top, names a directory, or does not exist is a **build error**.
Tests: `server/tests/build-staging-lib.Tests.ps1`.

**Rejected:**

- **Copying `mast-clone.ps1` into `server/providers/mast/` at build time.** This forks
  the shared file -- the exact property the mast-clone adoption exists to gain is one
  implementation serving units, the control host and dev boxes. A build-time copy is a
  second copy that drifts the first time someone edits the wrong one.
- **A `../../tools/mast-clone.ps1` entry in `commandfiles`.** Rejected because it is
  half-right in the most dangerous way: it resolves correctly on the source side, so it
  looks like it works, and then mirrors the relative path on the destination side and
  writes outside the staging root.
- **Preserving the source directory structure in staging** rather than flattening to the
  leaf name. Rejected for consistency with what `assets/*` already does and with how the
  unit-side executor works -- it runs every command with the staging root as its working
  directory, so a nested path simply would not be found at run time.
- **Tolerating a missing or out-of-tree entry with a warning.** Rejected in both
  directions: a build must not reach arbitrary paths on the build host, and a typo must
  break the build rather than silently omit a file whose absence surfaces later as a
  unit-side command that cannot find its script.
- **Putting resolution inline in the staging pass.** Split into a dot-sourceable lib
  instead, so containment rules -- the security-relevant part -- are testable without
  running a build.

**Unsettled:**

- **`repofiles` are a determinant of a module's deployed output exactly as its
  `commandfiles` are, so the per-module content hash must cover them -- and does not.**
  This cannot be wired here: `Get-ModuleContentHash` and `build/build-manifest-lib.ps1`
  live on `eli/per-module-tracking` (#22 Stage 1) and have not reached
  `eli/provisioning-v3`. Tracked as an explicit follow-up in
  `docs/mast-clone-adoption-plan.md` Stage 1, to be closed when the two branches meet.
  Until then a changed `mast-clone.ps1` is caught by the aggregate `payload_hash`, not
  per-module -- so it forces a whole-payload reprovision rather than a targeted one.
- **The mechanism is inert.** No module declares the key yet; Stage 3 of #31 is what
  adds `"repofiles": ["tools/mast-clone.ps1", "tools/mast-repos.tsv"]` to the `mast`
  module. Until then this is untested against a real build in the only way that counts.
- **Flattening by leaf name makes two repo files with the same basename collide** in
  staging. Nothing detects that today, because nothing declares the key.
