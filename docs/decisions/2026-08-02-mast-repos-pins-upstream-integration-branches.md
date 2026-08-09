---
decided: 2026-08-02
status: accepted
issue: MAST_provisioning#31
areas:
  - source-layout
  - providers
  - reproducibility
---

# The repo list names the upstream integration branches, with the ref always explicit

**Why:** The repo list still pointed at the personal fork's dev branch --
`elibrody-weizmann/MAST_unit.2024-12-12 eli/vm-provisioning` and
`elibrody-weizmann/MAST_common eli/vm-provisioning` -- set in May 2026 while
bringing MAST_unit up on the provisioning VM. Retiring the fork deleted the
MAST_common branch, so `provide-mast.ps1` would have failed at clone
on the next run: the module that installs MAST itself, broken by a cleanup
elsewhere. The fork branch was stale regardless (tip 2026-06-21, and its own
last commit was already repinning the submodule to `The-MAST-project` master),
and it predates the upstream requirements pinning of Jul-Aug 2026.

**What:** Both lines now name `The-MAST-project` with an explicit ref --
`MAST_unit.2024-12-12 main`, `MAST_common master`. The refs are given
explicitly, and the file says why: the two repos do not share one integration
branch, and an omitted ref silently follows whatever the remote default happens
to be at clone time. That pointer had in fact drifted -- MAST_common's default
named a dead 2024 `main` -- which is what motivated the rule; the dead branch
was deleted and the default corrected to `master` the same day
(`MAST_common#14`), so the pointer is right today and the explicit refs are
what keep a future drift from reaching the units. Integration branches were
derived from merged-PR bases and branch-tip recency, not from
`defaultBranchRef`.

**Rejected:**

- **Omitting the ref and letting each clone follow the remote's default branch.**
  The tidier-looking file, and rejected on evidence gathered the same day: MAST_common's
  default pointed at a dead 2024 `main`, so a defaulted clone would have laid a stub down
  on every unit and been hard to notice. Fixing the default was necessary but not
  sufficient -- an explicit ref is what stops a *future* drift from reaching the fleet.
- **Trusting `defaultBranchRef` to derive the integration branch.** Rejected for the same
  reason and stated as method: the branches were derived from merged-PR bases and
  branch-tip recency, because the org is split between `master` and `main` and the default
  pointer is demonstrably stale in at least one repo.
- **Assuming both repos share one integration branch name.** They do not -- `main` for
  MAST_unit.2024-12-12, `master` for MAST_common -- so any scheme with a single
  fleet-wide branch constant would be wrong for one of them.
- **Pinning to commit SHAs instead of branches.** Not taken here. It would make the
  deployed content immutable under a fixed module hash, which is the property the drift
  work wants, but it also means every upstream fix needs a provisioning commit to reach
  the fleet. Left to the per-module tracking stages rather than decided as a side effect
  of a broken clone.

**Unsettled:**

- **Both entries are still *branch* refs**, so the existing-clone path continues to
  `fetch` + `reset --hard FETCH_HEAD` and the deployed content moves under a fixed module
  hash. A unit can therefore change what it runs without any manifest noticing. Stages
  1b/2 of the per-module tracking work are what close that, and until they land the
  reproducibility claim below holds only per clone, not over time.
- **The correction to MAST_common's default happened elsewhere** (`MAST_common#14`) and
  is relied on here; nothing in this repo would notice if it drifted back.
- **The integration branches were derived, not declared.** They are inferred from PR
  bases and recency, which is the best signal available but not an authoritative
  statement from the repos themselves.

**Implications:** Provisioned units now receive the pinned `requirements.txt` from both
repos, so a unit venv becomes a deterministic function of the checked-out commit -- the
precondition that makes per-module hashing meaningful for the `mast` module (see
`docs/per-module-tracking-plan.md`, Stage 1b).
