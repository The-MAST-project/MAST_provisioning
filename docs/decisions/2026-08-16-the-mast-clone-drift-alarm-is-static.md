---
decided: 2026-08-16
status: accepted
issue: MAST_provisioning#31
areas:
  - source-layout
  - reproducibility
  - dev-harness
---

# The mast-clone drift alarm pins the manifest statically rather than driving the tool

**Why:** `#31` moved the unit's entire source layout onto `tools/mast-clone.ps1`, a tool whose primary consumer is the dev workflow. Its own *Risk: ownership shifts* section names the consequence: a `mast-repos.tsv` branch-pin edit made for development convenience becomes a fleet-affecting change, with nothing between it and the units. Locked decision 9 answered that with a dev-drift alarm owned by this repo, and the alarm was the condition on which the ownership shift was judged acceptable.

Stages 0-6 all landed and the migration completed on all four units (`2026-08-09-the-mast-clone-layout-migration-is-complete.md`), but the alarm never did. The plan document's completion banner records the stages, which is what made the omission easy to miss: the stages were the visible work, and the alarm was the safety property attached to them. Between mast-clone's adoption and today, an edit retargeting role `unit` at a feature branch would have reached the fleet on the next provisioning run with no test objecting.

**What:** `server/prov/tests/test_mast_clone_contract.py`, ten assertions in three groups.

The **golden snapshot** pins the exact rows role `unit` resolves to as (`dir`, `repo`, `branch`, `rev`) tuples, plus the `#!uv-version` directive. Adding a repo to the role, retargeting one, pinning a rev, or bumping the resolver fails the suite, and updating `EXPECTED_UNIT_ROWS` is the deliberate act acknowledging the change. Two derived assertions come free and are worth stating separately because their failure modes differ: the layout is exactly `{common, unit, claude}` (the three NSSM coordinates are built on it), and `MAST_common` is checked out as `common` (its repo root *is* the package, so any other folder name breaks every `from common.X import ...` in the fleet).

The **invocation surface** asserts `-Top`, `-Role`, `-Transport`, `-Update` and `-DryRun` are still declared, that `https` is still an accepted transport, that the script still prefers a staged `<Top>\.tools\uv.exe` over bootstrapping (stage 4 vendored that binary so provisioning needs no CDN), and that it still writes `mast.pth` (NSSM services inherit no shell env, so this is how `<Top>` reaches `sys.path`).

The **whole-file SHA-256** of `mast-clone.ps1` is the coarse backstop, so an edit no assertion covers still surfaces in review.

Both alarms were verified to fire, not merely to pass: retargeting the `unit` row at a feature branch fails the snapshot, and appending a comment line to `mast-clone.ps1` fails the checksum.

**Rejected:**

- **Pester driven through `-DryRun`**, which is what the plan called best. It would assert real behavior rather than the presence of code, and `-DryRun` exists precisely to print the planned actions without touching anything. Rejected on where it runs: Pester is the Windows-only CI job, so a manifest edit made on a Linux box would not be caught by the platform most likely to be making it, and the assertions could not be developed or verified on the machine this was written on. Static parsing runs in the pytest matrix on both platforms. The trade is real and is the weak point of this change -- see *Unsettled*.
- **Asserting the manifest contract instead of its contents.** `server/tests/mast-repos-manifest.Tests.ps1` already does that for `#75` (every row has an explicit branch, the rev column parses, the uv directive exists). It is the wrong instrument here: it passes for any branch, which is exactly the edit that must not pass silently.
- **Vendoring a copy of `mast-clone.ps1` into this repo and testing that.** Removes the shared-ownership risk by removing the sharing, and reintroduces the two-implementations problem `#31` existed to end.

**Unsettled:**

- **The invocation-surface assertions are textual, not behavioral.** `"$Top" in script` proves a parameter is declared, not that it still means what provisioning assumes. A rename would fail loudly; a semantic change to how `-Top` is interpreted would pass. The checksum is the only thing covering that case, and it covers it by forcing a human to look.
- **The snapshot pins today's manifest, which currently pins no revs.** All three `unit` rows track a branch, so the fleet still gets whatever the branch head was when its clone ran -- the drift `#75` exists to fix. This alarm catches a change to *which* branch, not movement *along* one.
- **Nothing asserts the `.sh` and `.ps1` parsers agree.** They share `mast-repos.tsv` and are maintained in parallel; this suite exercises the manifest through a third parse written for the test. A divergence between the two scripts is invisible here.

**Implications:**

- Every change to `mast-clone.ps1` or `mast-repos.tsv` now passes through a provisioning review gate before it can reach a unit, which is what locked decision 9 asked for and the last outstanding item of `#31`.
- Updating the snapshot is a normal, expected part of a legitimate change. A failure here is a prompt to review fleet impact, not evidence of a defect.
