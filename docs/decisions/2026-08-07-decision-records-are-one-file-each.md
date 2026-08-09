---
decided: 2026-08-07
status: accepted
issue:
areas:
  - docs-process
  - rationale retrieval
  - PR conventions
---

# Decision records are one file each, written for an agent to retrieve

**Why:** `DECISIONS.md` worked as a solo instrument and stopped scaling the moment the
repo had two contributors and a ticket-driven workflow.

Three failures, measured at the freeze (118 entries, 5,146 lines, 2026-05-04 to
2026-08-03):

- **A shared append anchor conflicts by construction.** Every entry is prepended at the
  top of one file, so any two concurrent branches that both record a decision conflict
  there. 104 commits touched the file. No amount of care fixes this; it is a property of
  the layout, not of the authors.
- **Date citations are already ambiguous.** 24 dates carry more than one entry --
  `2026-08-02` has nine, `2026-05-16` has eight. About 25 `see DECISIONS.md <date>`
  pointers exist across `README.md`, `CLAUDE.md`, `server/prov/transport.py`,
  `server/prov/driver.py`, and six providers; most already resolve to a multi-entry date.
- **The date stopped meaning anything.** An entry is written when the call is made and
  lands when its PR merges, sometimes weeks later, so the file's reverse-chronological
  order reflects neither.

Underneath those, a fourth issue that reframed the whole design: **the realistic reader is
a coding agent, not a browsing human.** Nobody reads a 5,000-line log to explain a
one-liner. The actual use is an assistant, mid-task, answering "why is this like this?"
from the repo. That inverts the usual advice about keeping a decision log short and
selective -- attention is no longer the scarce resource, and *retrievability from a code
location* is.

**What:**

- **`docs/decisions/YYYY-MM-DD-slug.md`, one file per decision**, replaces appending to
  `DECISIONS.md`. Format spec in `docs/decisions/README.md`.
- **The old log moves into the directory whole and frozen**, as
  `docs/decisions/archive-2026-05-04-to-2026-08-03.md` -- not split into 118 files, and not
  left at the root. It stays authoritative for what it covers, and its header states the
  freeze and points at the new format. A trial split was written and discarded (see
  *Rejected*).
- **Date-prefixed filenames, not ADR-style sequential numbers.** Sequential numbering
  would make two branches race for the next integer -- reintroducing the coordination
  problem being removed.
- **`decided:` plus `status: proposed | accepted | superseded`** carry the design/merge
  gap explicitly; git records when a record actually landed.
- **Two new body sections, `Rejected` and `Unsettled`**, alongside the archive's
  `Why` / `What` / `Implications`. They hold the alternatives not taken and what was
  knowingly left unknown or broken.
- **An anchoring rule**: every record names the file paths, script names, and symbols it
  concerns **in its prose**, so `git grep` from a symbol reaches it. Identifiers stay out of
  frontmatter -- a stale path inside a sentence about what was done on a date reads as
  history, while the same path in a metadata field reads as a claim about the present and is
  wrong as soon as the file moves.
- **An `areas:` field** naming what the decision is about, at any level of the system, drawn
  from a **living list in `AREAS.md`** -- reuse a term where one fits, coin and add one where
  none does. Descriptive rather than prescriptive: the list follows the records.
- **Three frontmatter keys stay editable after commit** (`status:`, `superseded_by:`,
  `areas:`) so supersession and vocabulary curation are possible; the body never is.
- **A per-PR `Why` requirement** in `CLAUDE.md`, giving the second retrieval path:
  `git blame` -> commit -> PR body.

**Rejected:**

- **Turn the log into a changelog, updated per PR or feature.** A changelog answers *what
  changed*, is release-facing, and is generatable from PR titles; a decision record
  answers *why, and what was rejected*, and is generatable from nothing. Merging them
  makes the changelog noisy with reasoning its readers do not want, and fragments the
  rationale into per-PR pieces with no standing form.
- **Let GitHub tickets be the decision record.** Tempting, since tickets already carry the
  discussion and give the team and supervisors observability. Rejected because tickets are
  not in the clone: the agent reading this repo cannot see them, which defeats the entire
  retrieval story. Tickets also close, and searching 300 closed issues is worse than
  searching a directory. Tickets stay the home for the *argument*; the outcome is distilled
  here.
- **Classic ADRs with `Context` / `Decision` / `Consequences`.** The section names are
  prediction-shaped and the register is ratifying -- it projects confidence and suppresses
  exactly the doubt that is worth recording. `Rejected` and `Unsettled` exist because the
  ADR template has no slot for them.
- **Writing records as invariants for future contributors.** An invariant is a prediction,
  and predictions rot. It also does not match how the work actually goes: users push for
  the most out of what exists and programmers reuse what is there, producing corner cases
  nobody could have enumerated in advance. Intent is a durable fact about a moment; a rule
  about the future is a guess. Standing rules live in `CLAUDE.md` instead, citing the
  record that produced them.
- **Splitting the 118 archive entries into individual files.** Tried and reverted: a script
  produced all 118 cleanly (the entry titles slugify well enough to name files directly),
  and the result was rejected on reading it. Splitting buys nothing -- the conflict churn
  occurs only on *new* entries, so the freeze already captures the whole benefit -- while
  costing a 118-file diff that reformats history, backdated frontmatter asserting a
  structure those entries were never written in, and the manual disambiguation of ~30
  citations across 24 multi-entry dates. Reading the archive top-to-bottom is also still the
  fastest way to absorb how the design got here, and that only works while it is one file.
- **Leaving the archive at the repo root.** Rejected so that "where is the rationale?" has
  exactly one answer: `docs/decisions/`. A root file beside the directory invites appends to
  the wrong surface.
- **Rewriting the ~30 `see DECISIONS.md <date>` citations** in providers, `transport.py`,
  `driver.py`, and the plan docs to the new archive path. Not worth touching 25 otherwise
  stable files for a doc move; the date in each citation is still exact and `git grep
  DECISIONS` lands on the archive. The path-to-archive mapping is stated in `CLAUDE.md`
  instead, which an agent always has loaded. Revisit if a reader is ever observed failing on
  a stale path.

**Unsettled:**

- **Whether the discipline survives contact with a second author.** The archive is 101
  entries by Eli and 3 by Arie. The format change does nothing about that asymmetry, and
  the real test is whether records get written by whoever makes the call rather than
  retroactively by one person.
- **Whether the `areas:` curation actually happens.** The field went through three shapes
  before this one, and the reasoning is worth keeping because each failure was different. It
  began as `touches:`, a list of paths and symbols -- wrong twice over, since paths rot and a
  metadata field asserts the present tense where prose asserts history. It then became a
  fixed vocabulary of ~23 terms -- rejected because a closed list forces each decision into
  the least-wrong bucket, and the decisions most worth recording are exactly the ones that
  fit no existing bucket. Fully free-form was honest but unqueryable, with synonyms
  accumulating and no grep spanning them.
  The current answer -- a list that is consulted for reuse but grows on demand -- gets both
  properties only **if someone periodically runs the inventory and merges drift**. Nothing
  enforces that, and it is precisely the kind of upkeep that quietly stops happening. If it
  does stop, the field degrades to the free-form case (still readable, not queryable) rather
  than breaking, which is why it is acceptable to try. Worth checking after ~20 records
  whether the list still resembles reality; if curation has not happened by then, drop the
  pretense of queryability and say so in the spec.
- **Retrieval is unproven.** No agent has yet been observed finding a record it needed
  from a cold start in this layout. Both paths (`grep` on symbols, blame -> PR) are
  plausible and neither is measured. The cheap check is to ask a fresh session "why does
  provisioning not map `Z:`?" and see whether it finds the record without being pointed at it.
- **Two shapes in one directory, permanently.** A `git grep` over `docs/decisions/` reaches
  both, which is the case that matters, but the archive is one 5,146-line file among dated
  records and no rule makes that obvious beyond its filename and header. Whether that reads
  as coherent or as an unfinished migration is untested.
- **The PR-body `Why` convention is cross-repo guidance living in a single repo.** By this
  repo's own layering it belongs in `mast-claude-config`. It is here provisionally, to be
  proven on one repo before promotion.

**Implications:**

- No conflicts on decision records from this point; two branches can each add one freely.
- The archive's *content* is untouched, so every existing citation's date still resolves;
  only the file's path changed. New citations use the slug and are exact.
- `git grep` over `docs/decisions/` is now the single search that covers all rationale,
  old and new -- the reason the archive moved into the directory rather than staying at
  the root.
- `MAST_provisioning` is the test bed. If the format holds here, promote the convention to
  `mast-claude-config` for the rest of the org; if it does not, only one repo carries a
  half-migrated directory.
- The bar for writing a record drops on purpose, so expect more records than the archive's
  pace of roughly 40 a month, not fewer.
