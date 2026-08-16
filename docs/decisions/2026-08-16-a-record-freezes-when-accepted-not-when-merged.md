---
decided: 2026-08-16
status: accepted
issue:
areas:
  - docs-process
  - rationale retrieval
---

# A record freezes when it is accepted, not when it reaches `main`

**Why:** the format written on 2026-08-07 assumed a record travels with its own diff. `status: proposed` was described as "still in review", to be flipped "in the same PR that lands the change", and the immutability rule drew its line at `main` -- the point where "a decision stops being in flight and other people start working against it". Both sentences are about a record whose code is in the same pull request.

`2026-08-12-one-nssm-service-supervises-an-interactive-monitor.md` is not that. It merged to `main` as `proposed` with no implementation at all, blocked on MAST_unit#132 (unit startup opens the mirror covers uncommanded) and on the unit's `/shutdown` being one-way. Nothing in the spec addressed the case, and the gap was not theoretical: #79 merged the record, and #80 then amended its body twice -- the resource-wait paragraph and the Forced-restart ordering. Under the `main` line that was a freeze violation; under the reading that "reached `main`" means the *decision* rather than the file, it was permitted and the record stays mutable indefinitely. The text supports both, which is the actual defect. Amending a merged proposal had nowhere legal to go, and it happened anyway, because a design under discussion has to be able to absorb the discussion.

Two further weaknesses surfaced on the same record and are fixed here rather than separately, since all three come from the one unexamined assumption:

- Its `areas:` coined `session isolation` and `hardware startup` without adding either to `AREAS.md`, which the spec requires in the same PR. `session isolation` was a synonym of the listed `service logon sessions` -- precisely the drift that makes the subject-to-record query unreliable, and precisely what the 2026-08-07 record's *Unsettled* predicted would quietly stop happening.
- Roughly half of it decides `MAST_unit`'s code -- `app.py`'s FastAPI lifespan, `Mount.__init__` calling `power_on()`, `PHD2Connector` building a `WatchedProcess`, the covers path in `covers.py` -- from inside `MAST_provisioning`. The anchoring rule spends its effort naming those symbols precisely, and none of it works: `git grep` in the `MAST_unit` clone does not reach this directory. The retrieval story was designed within one repo and silently assumed decisions would be too.

**What:**

- **The freeze binds on `status: accepted`, not on reaching `main`.** A `proposed` record is editable in place, body included, for as long as it is proposed. The three-editable-keys rule (`status:`, `superseded_by:`, `areas:`) now begins at the flip.
- **A `proposed` record may merge to `main` ahead of its code**, stated explicitly rather than left to inference, with three obligations: the freeze does not bind it; the landing PR rewrites the body to *what shipped* -- divergences moved into `Rejected` -- before flipping to `accepted`; and `issue:` is required, with the ticket open until the flip.
- **`issue:` becomes required on `proposed` records** and stays optional on accepted ones. A record on `main` reads as settled, and the ticket is the surface that says the argument is not.
- **A note to the reader** that identifiers in a `proposed` record name things that may not exist yet, and are worth grepping before they are believed.
- **A test for which designs earn the exception**: a design the team has committed to and cannot yet build is a decision; a design nobody has agreed to is a proposal and belongs on its ticket. The question is whether anyone would object to work starting along these lines, not whether work has started.
- **Cross-repo decisions land in the repo whose code they decide**, kept whole where the larger share of the change is, with a short record in each other affected repo naming that repo's own symbols and citing the full slug. Where a repo has not adopted the format, the citation goes in its `CLAUDE.md` or its issue instead.
- **`CLAUDE.md`'s restatement of the rule updated in step.** It carried its own copy of the immutability and rewrite-in-place paragraphs, which would otherwise contradict the spec at the surface an agent actually has loaded.
- **`AREAS.md` reconciled**: `hardware startup` added with its boundary against `instruments` spelled out, and `session isolation` moved to *Retired and merged* pointing at `service logon sessions`. The supervision record's `areas:` was retagged accordingly -- permitted on a proposed record, and permitted on an accepted one too, since `areas:` is navigation metadata.

The 2026-08-07 record keeps `status: accepted` and is **not** superseded. What is being changed is one rule inside it; the format, the directory layout, the sections, the anchoring rule and the agent-reader premise all stand, and flipping it to `superseded` would tell a reader the whole thing was replaced. The machinery available for "refined in one place" is the same machinery as for "reversed entirely", which is a limitation of the format worth noting more than a problem here.

**Rejected:**

- ***Keep `proposed` records on a branch until their code lands.*** The clean version of the rule, and it keeps every record on `main` true of the tree. Rejected because the artifact the team most needs while blockers clear is exactly the one it would hide, on a branch that could stay open for months and drift from `main` the whole time. The supervision record is blocked on two defects in another repo; nobody would have read it.
- ***Treat a merged proposal as frozen and require a superseding record for every amendment.*** Consistent with the existing rule and wrong in practice: it would have turned #80's two clarifications into two more files, and a supersession chain within one unbuilt design is exactly what the 2026-08-09 consolidation rejected. Freezing is worth its cost for a belief someone acted on, not for a draft.
- ***A separate `docs/design/` directory for pre-implementation designs, extracting a record when the work lands.*** Conceptually the cleanest -- the two artifacts genuinely differ in what they promise -- and rejected because it splits "where is the rationale?" back into two answers, which the 2026-08-07 record went out of its way to avoid when it declined to leave the archive at the root. It also duplicates: the design and the record extracted from it would share most of their prose, and the `Rejected` section would live in the older, wronger copy.
- ***Ban design-shaped records outright and keep them on tickets.*** This is the position the format already argued against: tickets are not in the clone, so an agent reading the repo cannot see them. It would also have discarded the strongest part of the supervision record -- six rejected alternatives with reasons, including why job objects defeat adopt-don't-respawn and why `New-SmbGlobalMapping` loses to MAST_common#26 -- which has no other durable home.
- ***Fragment the cross-repo decision into one record per repo.*** Each fragment would be individually incoherent: the reason the watcher is LocalSystem is `WTSQueryUserToken` needing `SE_TCB_NAME`, and the reason PHD2 leaves the unit process is that it must outlive a unit stopped for maintenance. Neither survives being told from one repo's side. The stub-plus-citation shape keeps the argument whole and still findable.

**Unsettled:**

- **The stub records do not exist yet.** `MAST_unit` has no `docs/decisions/`, so the cross-repo rule currently has no instance -- the supervision record's unit-side half remains unreachable from the unit clone, which is the concrete problem the rule was written for and does not itself fix. Whether the format is promoted to `mast-claude-config` for the org, or stubs are hand-placed per repo, is open; the 2026-08-07 record made promotion conditional on the format holding here.
- **Whether a rewritten-on-landing body is honestly a historical record.** The rule says the landing PR replaces the proposal's prose with the mechanism as built. That is the right thing to freeze, but it means the frozen text was written *after* the fact for a decision dated months earlier, which is the retrospective-record failure mode the `decided:` field exists to avoid. The `Rejected` section carrying the divergences is what is supposed to hold the difference; whether it does depends entirely on whoever lands the change bothering.
- **Nothing enforces the flip.** A `proposed` record whose work is quietly dropped stays on `main` describing an architecture nobody is building, indistinguishable by grep from one still queued. `grep -l 'status: proposed'` is the only inventory and nobody is obliged to run it. An age check -- a proposal older than some months is either accepted, rejected, or a lie -- is the obvious mechanism and is not implemented.
- **`issue:` is required by prose alone.** No check rejects a `proposed` record without one, and the field was already empty on two accepted records before this rule existed.
- **The supervision record and #82 now overlap heavily.** The epic restates the shape diagram, the unsettled list and the boundaries rather than pointing at them, which is the duplication the one-job-per-surface habit exists to avoid: two surfaces to reconcile when the design moves, and no rule saying which is authoritative. The record is, by the definition here -- but the epic is what a reader lands on from the issue list. Whether an epic homing a `proposed` record should be a pointer or a summary is unresolved, and the answer probably differs before and after the code exists.
- **Whether the freeze line is now harder to remember, not easier.** "Frozen once merged" is a rule anyone can apply from `git log`; "frozen once accepted" requires reading a frontmatter field that a reader has to think to check. The gain is that the rule is now true; the cost is that its enforcement point is invisible in the history.
- **The supersession machinery still has one setting.** Refining a single rule inside a multi-rule record has no representation: `supersedes:` would overstate, and this record therefore cites 2026-08-07 in prose only, which the subject-to-record path cannot follow. Fine at two docs-process records, worse at ten.

**Implications:**

- The supervision record is legitimately amendable while it stays `proposed`, and #80's edits are retroactively within the rule rather than outside it.
- Its `issue:` is now `MAST_provisioning#82`, the supervision epic, opened the same day this rule was written and previously the record's missing half: the record had merged to `main` with no open surface saying its argument was still live.
- Its landing PR now owes a body rewrite, not just a one-line status flip -- the largest change here, and the one most likely to be skipped.
- `grep -l 'status: proposed' docs/decisions/2*.md` becomes the standing list of records that describe design rather than code. It has one entry.
- The `areas:` inventory in `AREAS.md` was run and reconciled for the first time since the list was seeded, on the fourteenth record after the format landed. The 2026-08-07 record set that check at roughly twenty, and the drift it was looking for had already appeared -- one coined synonym and one unlisted term, both on the first record written by the second author.
