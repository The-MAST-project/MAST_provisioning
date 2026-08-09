---
decided: 2026-07-23
status: accepted
issue: MAST_provisioning#22
areas:
  - drift
  - providers
  - reproducibility
---

# `build-manifest.json` carries per-module content hashes, covering injected command args

**Why:** Drift detection is whole-payload: the single `payload_hash` over the
flattened staging tree can say a unit differs from the build but not *which
module*, so any drift means a full reprovision. The per-module-tracking epic
(#22) needs a per-module fingerprint on the build side first (Stage 1). The
hash boundary must cover more than file bytes: a module's deployed output is
also shaped by build-time injected command args (`-Site`, `-ForceMode`,
`-RpiNtp`, the desktop-shortcut `-FastApiUrl` -- which lives only in
`module.json` `command`), which no staged-file hash sees. The worked example
that must register as drift: repointing the FastAPI shortcut URL changes no
commandfile byte at all.

**What:** `build-manifest.json` gains `module_state`: per module `{version,
hash}`. `Get-ModuleContentHash` (in the new dot-sourceable
`build/build-manifest-lib.ps1`, where `Get-PayloadHash` also moved so Pester
can test both without running a build) hashes (a) the module's source
commandfiles under `server/providers/<module>/` -- hashed at the source, since
staging is flattened and has no per-module subtree; (b) the module's
**resolved** `commands.json` entries (provide + verify + any finalize), i.e.
the command strings with the injected args baked in; (c) the resolved version
(`git` -> SHA, as in `module_versions`). File lines sorted by path, command
lines order-preserving (execution order is behavior), category prefixes
(`file:`/`cmd:`/`version:`) keep inputs collision-free. Missing commandfiles
are skipped -- by hash time a gap can only be a `-TestMode` optional payload;
production builds have already thrown in the staging pass. `module_versions`
stays alongside as a deprecated duplicate (`tools/fleet-drift-report.py` still
reads it; removed when the report keys on `module_state` in Stage 3). The
aggregate `payload_hash` is unchanged as the fast "anything changed?" gate.
Tests: `server/tests/build-manifest-lib.Tests.ps1`.

**Rejected:**

- **Hashing only the module's staged files.** The obvious per-module fingerprint,
  and demonstrably insufficient: staging is flattened, so there is no per-module
  subtree to hash, and -- the sharper problem -- a module's behavior is partly
  determined by args injected into `module.json` `command` at build time. The
  FastAPI shortcut is the worked counterexample: repointing it changes not one
  staged byte, so a file-only hash reports no drift on a change that redeploys a
  different shortcut.
- **Hashing the module version alone** (the existing `module_versions`). Rejected
  as too coarse in the direction that matters: a `git`-resolved SHA moves when any
  repo commit lands, including ones that touch nothing this module deploys, and does
  not move when a build-time arg changes.
- **Removing `module_versions` immediately** now that `module_state` carries the
  version. Kept as a deprecated duplicate because `tools/fleet-drift-report.py`
  still reads it; it goes when the report keys on `module_state` in Stage 3. Deleting
  a field while a consumer still reads it would have broken the report for the
  intervening stages.
- **Replacing the aggregate `payload_hash`.** Kept unchanged as the fast
  "anything changed at all?" gate -- the per-module hashes answer a different, more
  expensive question, and both are cheap to carry.
- **Failing the build on a missing commandfile at hash time.** Rejected as
  redundant and misplaced: production builds have already thrown in the staging
  pass, so by hash time a gap can only be a `-TestMode` optional payload. Skipping
  keeps the error where it is actionable.

**Unsettled:**

- **Build-host-vendored payloads sit outside the per-module hash boundary**
  (cygwin-pkg-cache, mast-indexes, NetFx3 SxS, licenses). Their staged bytes are still
  caught by the aggregate `payload_hash`, so drift in them means a whole-payload
  difference with no per-module attribution. The same accepted boundary is documented
  in #24 for the release version.
- **This is Stage 1 of four, and only the build side.** Nothing consumes `module_state`
  yet: Stage 2 merges `{version, hash}` per executed module into a cumulative
  `installed-manifest.json`, Stage 3 adds per-module drift classification and targeted
  `-Modules` updates. Until then the field is written and unread.
- **The hash's completeness is an argument, not a proof.** It covers the output
  determinants known at the time -- commandfiles, resolved command strings, version.
  A future mechanism that shapes deployed output through some other channel would be
  invisible to it, in exactly the way the injected args were before this change.
- **Hashing commandfiles at the source rather than in staging** assumes the two are
  byte-identical for every module. True for how staging copies them today.

**Implications:** Stage 2 can merge `{version, hash}` per executed module into a
cumulative `installed-manifest.json`; Stage 3 gets per-module drift classification and
targeted `-Modules` updates. Plan: `docs/per-module-tracking-plan.md`.
