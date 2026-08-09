---
decided: 2026-08-02
status: accepted
issue: MAST_provisioning#31
areas:
  - source-layout
  - dev-harness
---

# The personal fork is retired; a single `origin` points at the integration repo

**Why:** Every clone carried two remotes -- `origin` = `elibrody-weizmann/<repo>` and
`upstream` = `The-MAST-project/<repo>` -- a layout no fresh `git clone` produces, so the
word "origin" meant different repositories depending on which machine you typed it on. The
fork had also stopped earning its keep: work is pushed straight to branches on the
integration repo, and 12 of 13 open PRs already had their head branch there. Auditing the
forks found their remaining exclusive content was either already reapplied upstream or
obsoleted by the config-file epic.

**What:** The forks' remaining branches were deleted, then in each clone `origin` (the
fork) was removed and `upstream` renamed to `origin`. Two machines hold MAST checkouts --
this one and the Windows provisioning box -- and both were converted in the same pass, so
no window existed where "origin" was ambiguous between them. `MAST_scheduler` and
`mast-claude-config` were untouched: the former has no upstream repo (the fork *is* the
repo), the latter already pointed at The-MAST-project.

**Rejected:**

- **Keeping the fork and renaming the remotes** so `origin` meant the integration repo
  and the fork got a different name. Rejected because it preserves the thing that had
  stopped paying: a staging repository nobody was staging through. 12 of 13 open PRs
  already had their head branch upstream, so the fork's actual role was to be skipped.
- **Converting one machine at a time.** Rejected deliberately: a window where `origin`
  means the fork on the Windows box and the integration repo on this one is precisely
  the ambiguity being removed, and a push during that window goes somewhere nobody
  expects. Both machines were converted in the same pass.
- **Preserving the fork's remaining branches** in case something in them was still
  wanted. Audited first rather than kept on principle -- the exclusive content was
  either already reapplied upstream or obsoleted by the config-file epic, so keeping
  them would have preserved noise and an invitation to push there again.
- **Rewriting every script, note and agent instruction that says `git fetch upstream`.**
  Not done as part of this change; they are simply wrong now and read as plain
  `git fetch`.

**Unsettled:**

- **Branches become public the moment they are pushed.** With no fork staging step,
  pushing publishes on the shared repo immediately, so branch names and half-finished
  work are visible to everyone. That is a change in working style that was accepted
  without discussion.
- **Documentation and habits still carry the two-remote model** across scripts, notes
  and agent instructions, and nothing sweeps them.
- **The audit of "remaining exclusive content" was a judgment call** made by reading the
  fork branches, not by a mechanical diff that proves nothing unique was lost.
- **`MAST_scheduler` remains a fork that is its own upstream**, so the org's remote
  layout is uniform for every repo except that one.

**Implications:** `git fetch` / `git push` with no remote argument now reach the
integration repo, and a fresh clone matches an existing checkout exactly.
