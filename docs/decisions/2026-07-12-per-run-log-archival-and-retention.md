---
decided: 2026-07-12
status: accepted
issue: MAST_provisioning#10
areas:
  - logging
  - orchestration
  - storage
---

# Each run owns its full log set, pruned by a keep-newest-N count cap

**Why:** Every run scattered evidence with no lifecycle: the controller log already landed under
`C:\MAST\logs\prov\sessions\<run-id>\`, but the unit's *own* session dir (acquisition, per-provider,
execute logs) piled up on the unit under a timestamp name and was never pulled back, `last-run.json`
held only the latest cycle, and nothing ever pruned old dirs -- unbounded growth on a host meant to
run for weeks-to-years unattended. A post-mortem depended on nothing having overwritten the evidence.
This is item 5 of `MAST_provisioning#10` -- the log *lifecycle*, distinct from item 4 (log *noise*).

**What:** The run driver now owns each run's full log set under one per-`run_id` location:

- **Deterministic unit session dir.** `client/execute-mast-provisioning.ps1` keys its session dir on
  the server-supplied `-RunId` (`C:\MAST\logs\sessions\<run-id>`) when present, instead of a local
  timestamp -- so the controller knows the exact path to pull. Manual runs (no `-RunId`) keep the
  timestamp-named dir; an explicit `MAST_LOG_SESSION_DIR` still wins.
- **Pull the unit logs back.** In the per-unit `finally` (while the PSSession is still open) the
  driver `Copy-Item -FromSession`s the unit's session dir into `<run-log-dir>\unit-<hostname>\`.
  Every non-dead session hits this -- success, smoke-fail, proxy-fail -- i.e. exactly when the
  unit-side logs matter.
- **Per-run status snapshot.** `last-run.json` is also written into the run's own dir, so this run's
  outcome stays pinned next to its logs after the live file is overwritten next cycle.
- **Bounded retention.** New `-RetainRuns` (default 60) keeps the newest N run dirs and prunes the
  rest at end of run. The delete DECISION is a pure function (`Select-MastProvPrunableRuns` in
  `server/lib/mast-log-archive.ps1`, keep-newest-N by the run id's embedded timestamp); the
  filesystem runner (`Invoke-MastProvRetention`) is a thin wrapper. Non-conforming dir names are
  never pruned, and the current run is always the newest so it is never eligible.

**Rejected:**

- **An age-based retention policy** ("keep 30 days"), or age and count together. Rejected in
  favor of a count cap as the single knob: a count is the one that actually bounds growth, and
  it is obviously correct without knowing how often runs happen. An age cap on a host that runs
  hourly and a host that runs weekly bounds two very different amounts of disk. An age dimension
  can be added later without weakening the guarantee this one makes.
- **Leaving the unit-side logs on the unit** and fetching them by hand during a post-mortem.
  This is the status quo, and it fails exactly when it is needed: the evidence is on a machine
  that may be offline, unreachable, or already overwritten by the next run's timestamp dir.
- **Keeping the timestamp-named session dir and having the driver search for it.** Rejected
  because the driver would have to guess which directory belongs to this run, which is
  ambiguous precisely when two runs are close together. Keying on the server-supplied `-RunId`
  makes the path derivable rather than discoverable -- while manual runs, which have no run id,
  keep the timestamp behavior.
- **Pruning by deleting inside the same function that walks the filesystem.** Split
  deliberately: the keep-newest-N decision is a pure function so it can be tested without a
  filesystem, and the runner that deletes is thin enough to read. Deletion logic that cannot be
  unit-tested is the wrong thing to be clever in.

**Unsettled:**

- **A dead session's unit-side logs are still lost.** The pull happens in the per-unit `finally`
  while the session is open, so a network drop -- the case most in need of a post-mortem -- leaves
  the evidence on the unit. This is the same limitation as lease release, and it was accepted
  rather than solved.
- **`-RetainRuns 60` is a guess**, unanchored to disk size or run frequency.
- **Pruning happens at end of run**, so a run that dies before its end prunes nothing, and disk
  is bounded only across successful runs.
- **Non-conforming directory names are never pruned**, which is the safe direction but means a
  naming change would silently create a set of directories that grow forever.
- **The pull's cost is assumed small** -- text logs, not FITS -- which holds for what providers
  log today and would not if a provider ever wrote a large artifact into the session dir.

**Implications:** The pure retention logic is covered by `server/tests/mast-log-archive.Tests.ps1`;
the pull-back and prune I/O carry real-run acceptance on the VM and unit. Post-mortems stop
depending on nothing having overwritten the evidence.
