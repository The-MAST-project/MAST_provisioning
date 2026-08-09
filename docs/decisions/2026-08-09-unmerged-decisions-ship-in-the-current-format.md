---
decided: 2026-08-09
status: accepted
issue:
areas:
  - docs-process
  - rationale retrieval
---

# Decisions that never reached `main` ship in the current format; the merged archive stays whole

Refines `2026-08-07-decision-records-are-one-file-each.md`, which rejected splitting the
archive. That record's reasoning is not overturned -- it is narrowed to the entries it was
actually about. Its status stays `accepted`: one file per decision, a frozen archive, and
`Rejected`/`Unsettled` as structural sections are all unchanged.

**Why:** The archive was assembled from both sides of a `main` merge, so it contained two
populations that look identical and are not. 91 entries had merged to `main` and are
history. **27 were written on `eli/provisioning-v3` and have never reached `main`** -- they
describe decisions still open in review on PR #36 at the time of writing, in the batch that
carries the autonomous loop, the Python port, SSH transport and per-module drift.

The 2026-08-07 record rejected splitting the archive, and gave four reasons. Checked
against these 27 rather than against all 118, two of them do not apply and two are answered:

- *"Backdated frontmatter asserting a structure those entries were never written in."* This
  is the objection that survives, and it is met by writing the records rather than
  mechanically converting them: each was rewritten against its issue thread, so `Rejected`
  and `Unsettled` state alternatives that were actually argued and questions that were
  actually open, not sections reverse-engineered to fill a template.
- *"The conflict churn occurs only on new entries, so the freeze already captures the whole
  benefit."* True for merged history. These entries are not history yet -- they are the
  ones a second contributor is reviewing now, and the ones most likely to be refined before
  they land.
- *"Manual disambiguation of ~30 citations across 24 multi-entry dates."* Bounded and, for
  this subset, an improvement: 11 dated citations point into the extracted range, six of
  them at `2026-07-12`, which carried five entries and was ambiguous already. Those six now
  name a slug.
- *"Reading the archive top-to-bottom is the fastest way to absorb how the design got
  here."* Preserved, because what remains is exactly the merged history -- a reader
  following how the system reached `main` reads one file, uncut.

The decisive point is one the earlier record did not consider, because it treated the
archive as a single object: **format is chosen once, when a decision lands.** A record
frozen in the old format is frozen for good, and these 27 had not landed. Writing them in
the current format before the branch merges costs one rewrite now instead of leaving the
repo permanently split between decisions that carry `Rejected` and `Unsettled` and
decisions that never will.

**What:**

- The 27 branch-origin entries became individual records under `docs/decisions/`, dated
  `decided:` to the day the call was made, not to today.
- Each was rewritten, not migrated: `Why` / `What` / `Implications` carry the original
  account, and `Rejected` / `Unsettled` were researched from the issue and PR threads
  (`#6`, `#7`, `#10`, `#17`, `#20`, `#22`, `#25`, `#31`, PRs `#13`, `#33`, `#36`, `#40`).
  Where a source records no alternative, none is invented.
- They were removed from `archive-2026-05-04-to-2026-08-03.md`, whose contents now end at
  2026-07-29. The **filename is unchanged on purpose** -- it names what the file was
  (`DECISIONS.md` through 2026-08-03), and its header states the current span, so the ~30
  path citations mapped in `CLAUDE.md` keep resolving.
- The archive header's counts were corrected: 118 entries to 91, and 24 multi-entry dates
  (`2026-08-02` with nine) to 19 (`2026-05-16` with eight).
- Dated `see DECISIONS.md <date>` citations pointing into the extracted range were
  repointed at slugs.

**A record stays editable until its decision reaches `main`, and supersession is for what
has landed.** The spec already said an uncommitted record may be edited freely; the line
is drawn at `main` rather than at any commit, because that is where a decision stops being
in flight. While a branch is open, a decision that changes mid-review is **rewritten in
place to state where it ended up** -- no second record, no `superseded` status, no
in-branch supersession chain. A reviewer reads what the PR proposes, not an archaeology of
how it got there; the argument belongs on the PR, which is where it happened. Supersession
stays what it was built for: revising something already merged, which cannot be rewritten
because other people are working against it.

Two records were consolidated under this rule. `2026-08-02-drift-review-fixes.md` recorded
three defects found reviewing #33 against
`2026-08-02-per-module-drift-decides-what-runs.md`; the two are now one record stating the
design that actually landed, and the three defects became `Rejected` entries -- which is
the better home for them anyway, since each is a concrete thing that was tried and failed.
The 2026-07-12 pair (`...port-server-orchestration-to-python` and
`...ssh-first-transport-and-utf8-no-bom`) stay separate, because they are two decisions
about different layers taken the same day, not one decision revised; what was dropped is
the "directional, not yet committed" framing, which described a moment rather than a
position.

Prose supersession of a **frozen** archive entry is unaffected and stays: the 2026-07-20
`config.toml` record supersedes the archived 2026-06-29 `config-bootstrap` entry, and says
so in prose because archive entries have no slug for `supersedes:` to name.

**Rejected:**

- **Leaving the 27 in the archive and writing nothing.** The status quo, and it freezes
  decisions still under review into a format the repo has left. It also means the first
  cohort of records in the new directory would be everything decided *after* the format
  changed, while the batch that most needs `Rejected` and `Unsettled` -- the one being
  reviewed -- has neither.
- **Copying them into records and leaving them in the archive too.** Rejected outright:
  duplicated rationale in two places, with nothing to say which is authoritative, is the
  ambiguity this directory exists to remove.
- **Splitting all 118.** Still rejected, on the 2026-08-07 reasoning, which holds for the
  91 merged entries: reformatting history, a diff nobody can review, and the loss of the
  single readable narrative. Nothing here argues for it.
- **A mechanical conversion** -- frontmatter plus the existing body, with `Rejected` and
  `Unsettled` left empty or filled from the prose alone. Considered as the cheap option
  and rejected: empty sections would misrepresent well-argued decisions as unconsidered,
  and the alternatives are recoverable, because the issue threads recorded them at the
  time.
- **Renaming the archive to `archive-2026-05-04-to-2026-07-29.md`.** Accurate about
  contents, and rejected: the body of the committed 2026-08-07 record names the current
  path and may not be edited, so a rename would strand it, and `CLAUDE.md` maps ~30 code
  citations onto that path.
- **Superseding within the branch** -- keeping a record and adding a second one that
  corrects it, with `status: superseded` on the first. Tried and reverted: it produced a
  reader who has to hold two records in their head to learn one current position, in a
  branch where the position is simply what the PR proposes. It also forced a choice
  between two wrong frontmatter states, since a record whose design still stands but whose
  details changed is neither `accepted` nor `superseded`.
- **Adding a `refines:` frontmatter field** for the partial case, once superseding proved
  too blunt. Rejected as solving the wrong problem: the partial case only arises from
  keeping in-flight history that should be rewritten instead. With the editing rule above,
  no record in this batch needs it.

**Unsettled:**

- **Where "editable" ends is now `main`, and nothing enforces it.** A record for a decision
  that has merged must not be rewritten, and the only thing preventing it is a reader
  checking whether the change is on `main` yet. On a long-lived branch that check is easy
  to get wrong in the permissive direction.
- **The rule assumes a branch's history lives on its PR.** That holds while review happens
  on GitHub; a decision revised in a branch that never opens a PR would leave the
  intermediate reasoning nowhere.
- **`Rejected` and `Unsettled` are reconstructed**, from issue threads written at the time
  by the person who made the calls. That is the best available source and it is not the
  same as having been written alongside the decision. A reader should weight them as
  contemporaneous evidence, not as contemporaneous authorship.
- **The `supersedes:` frontmatter is unused across all 27.** The one supersession in the
  batch points at an archive entry, which has no slug for the field to name, so it is
  prose. Whether the field is worth keeping, or whether prose is simply how this repo does
  it, will not be known until a record supersedes a merged record.
- **The split now has a rule that has to be explained**, not one a reader infers: the
  archive holds what merged to `main` before this branch, and everything from this branch
  onward is a record. Nothing in the directory listing shows that.
- **Whether this was worth doing at all** is a judgment about how much these 27 decisions
  will be read. If PR #36 merges without much review, the rewrite bought little.

**Implications:** The v3 branch ships its rationale in the format the repo actually uses,
with alternatives and open questions attached to the decisions a reviewer is looking at.
The archive becomes exactly one thing -- the decisions that reached `main` before this
branch -- which is a cleaner boundary than the merge artifact it was.
