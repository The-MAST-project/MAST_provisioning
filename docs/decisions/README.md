# Decision records

One file per decision, dated and slugged. This directory succeeds the root `DECISIONS.md`,
which moved here whole as `archive-2026-05-04-to-2026-08-03.md` and is frozen.

## Who reads these

**Primarily a coding agent, not a browsing human.** Nobody scans a 5,000-line log to
explain a one-liner, and nobody will scan this directory either. The realistic reader is
an assistant answering *"why does this code work this way?"* mid-task, and reporting back
something like: *"a decision on 2026-08-03 chose X over Y because Z -- which may change
what you were about to do."*

Two consequences, and they drive everything below:

- **Volume is not a cost.** Write a record whenever a change embodied a judgment call.
  Do not ration them to preserve human attention -- that was the old file's constraint,
  not this one's.
- **Retrievability is the whole cost.** A record an agent cannot find from the code is
  worse than no record, because the agent answers confidently from the code alone. Hence
  the anchoring rule.

## Why one file each

- **No merge conflicts.** Every writer appended at the same anchor -- the top of one file
  -- so any two concurrent branches touching it conflicted. That is structural, not a
  discipline problem; sharding is the only fix.
- **Unambiguous citations.** As of the freeze, 24 dates in the archive carried more than
  one entry (`2026-08-02` had nine). Every `see DECISIONS.md <date>` pointer into those is
  a guess. A slug is exact.
- **Honest dates.** A record is written when the call is made and merges whenever its PR
  merges, sometimes weeks later. `decided:` states the former; git records the latter.

## Naming

    docs/decisions/YYYY-MM-DD-short-slug.md

Date-prefixed, not sequentially numbered. Sequential ADR numbers force two branches to
race for the next integer -- the same coordination problem this directory exists to
escape. The date comes from a real `date` invocation (`(Get-Date).ToString('yyyy-MM-dd')`
on Windows), never a guess, and is the date the decision was **made**.

## Frontmatter

A YAML block first in the file, then an H1 stating the decision as a claim (not a topic):
"Z: belongs to the operational share", not "Drive letter handling".

```yaml
---
decided: 2026-08-03
status: accepted          # proposed | accepted | superseded
issue: MAST_provisioning#25
areas:
  - drive letters
  - the operational share
  - service logon sessions
superseded_by:            # slug of the record that replaces this one, when status: superseded
supersedes:               # slug(s) this record replaces
---
```

- **`status`** carries the merge lag explicitly instead of leaving the date to imply it.
  Open a record as `proposed` while the decision is not yet built; flip to `accepted` in the
  PR that lands the change. A `proposed` record may itself merge to `main` ahead of its code
  -- see *Proposed records ahead of their code* under *Immutability* for what that costs and
  what it obliges.
- **`areas`** names what the decision is *about*, at any grain, drawn from the living list in
  `AREAS.md` -- or coined and added there. See below.
- **`issue`** points at the ticket carrying the discussion. The record carries the
  outcome; the ticket carries the argument. **Required on a `proposed` record**, and
  optional once a decision is `accepted`: while a decision is still unbuilt the argument is
  live, and a reader who disagrees with the record needs somewhere to say so that is not a
  commit on `main`. An accepted record's argument is over, so a missing ticket costs nothing.

### `areas`: a curated, shifting list

Write the two to four things you would say if a colleague asked what this decision was
about. **Any level of the system is fair game** -- `storage` and `service logon sessions`
and `platform independence` are all legitimate, and mixing grains in one record is normal.

**Check `AREAS.md` and reuse a term when one fits. If nothing does, coin one and add it
there in the same PR.** That file is the living list of terms in use: descriptive, seeded
from what the archive actually decided about, and revised as the system changes. It is not a
fixed taxonomy to classify into -- the decisions most worth recording tend to be the ones
that fit no existing bucket, and forcing those into the least-wrong term loses the specific
thing the record was about. Reuse is worth something (scattered synonyms make the field
useless), but never at the price of a wrong tag.

Two mechanical rules, both load-bearing:

- **Block list only** -- one `  - term` per line. The inline `areas: [a, b]` form is
  invisible to the inventory command in `AREAS.md`, so its terms drop out of the list
  silently and the curation rots.
- **No file paths, line numbers, symbol names, or commit hashes.** Those rot the moment code
  moves, and frontmatter is the worst place to meet a stale path; identifiers belong in the
  prose, where they read as history rather than as a live index (see *Anchoring*). Areas
  describe the subject, which stays true.

## Body sections

Keep `Why` / `What` / `Implications` -- the archive's 118 entries are in that idiom and
there is no reason to fork it. Two sections are added, because they hold the highest-value
payload and the old format had no slot for them:

```markdown
**Why:** the problem, in the words used at the time -- what we were trying to achieve,
what we believed about the system, what forced the change.

**What:** the change made, concretely, naming files and symbols.

**Rejected:** the alternatives considered and not taken, each with the reason --
specific enough to be *recognizable later*. This is what lets a reader say "you are
about to do the thing they rejected, and the reason no longer holds."

**Unsettled:** what was not known, what was knowingly left broken or unhandled, which
assumptions were load-bearing but unverified, and what upstream debt this creates.
Omit the section only when there genuinely is none -- which is rare.

**Implications:** consequences and follow-on work.
```

`Rejected` and `Unsettled` are the point of the exercise. The archive produced them
sporadically and by accident (the 2026-08-03 `Z:` entry's closing paragraph on `Filer`
taking a UNC path is an `Unsettled` item buried in `Implications`). Make them structural.

## Register: write beliefs as beliefs

State what was believed **at the time**, attributed to the moment -- *"the services were
understood to run as LocalSystem (confirmed on mast03)"* -- not as standing truth.

A human-read log self-corrects, because readers object to entries that are wrong. An
agent-read log does not: a wrong rationale gets cited authoritatively for as long as it
sits there. A record written in the past tense of belief stays safe to cite even after the
belief turns out to be false, because the reader learns *what we thought*, which is still
true. A record written as timeless fact does not.

For the same reason: **do not write invariants or predictions about future work.** "Never
map `Z:` to anything of our own" is a rule, and rules belong in `CLAUDE.md` where the
agent reads them as standing guidance. A decision record's job is to preserve intent, not
to guess what a future contributor might be inclined to do. In practice, contributors reuse
and stretch what exists in ways nobody predicts; the record earns its keep by explaining the
mindset behind the current shape, so the stretch can be reasoned about.

## Anchoring: name the identifiers in the prose

**The prose is the only place identifiers live, so it carries the whole symbol-level
retrieval story.** Name the concrete things a decision concerns -- file paths, script names,
provider directories, function and class names, service names, registry keys, issue numbers
-- in the body, spelled exactly as they appear in the code. A record about "the stage stall"
that never writes `_ensure_carriage_home` is unreachable from the code it explains.

This is not a burden: a record that explains a real decision names these things anyway,
because it cannot be specific without them. The archive's entries do it naturally.

Write them as part of the account, not as a manifest -- *"execute's `Z:` block is gone, and
with it its `-ProvServer` / `-SmbUser` / `-SmbPass` parameters"*, not a bulleted list of
touched files. A stale path inside a sentence about what was done in 2026-08-03 reads
correctly as history. The same path in a frontmatter field reads as a claim about the
present, and is wrong the moment the file moves -- which is why `areas:` holds subjects
instead.

Retrieval works three ways; the prose feeds the first two:

- **code -> record**: `git blame` -> commit -> PR body -> the record it cites. Fed by the
  PR-body *Why* convention (see `CLAUDE.md`).
- **symbol -> record**: `git grep -il '<symbol>' docs/decisions/`. Fed by this rule.
- **subject -> records**: `git grep -l '^  - storage$' docs/decisions/` for every decision
  taken about one area. Fed by `areas:`, and only as reliable as the curation in `AREAS.md`
  -- a term nobody reused, or a synonym nobody merged, is a record this path misses. Treat it
  as a good first sweep, not a complete one, and fall back to full-text grep.

## Immutability and superseding

**A record freezes when its `status:` becomes `accepted`**, not when the file reaches
`main`. From that point it is never edited -- not for staleness, not for cleanup. The value
is the historical belief, which an edit destroys.

When such a decision is reversed or refined, write a **new** record with `supersedes:` set,
and in the same PR flip the old one's `status:` to `superseded` and fill its
`superseded_by:`. A superseded entry in the frozen archive has no slug, so name it in prose
instead and leave the frontmatter alone.

**While a record is `proposed`, it is editable -- rewrite it in place.** A decision that
changes before it is accepted gets **one record stating where it ended up**, not a record
plus a correction: no second file, no `superseded` status, no supersession chain within a
single decision. The argument about how the decision moved belongs on its PR and its
`issue:`, which is where it happened; a reader should meet what is proposed, not an
archaeology of how it got there. Two records were consolidated under this rule on
2026-08-09 -- see `2026-08-09-unmerged-decisions-ship-in-the-current-format.md`.

Rewriting in place does not mean discarding what was learned: an approach that was tried
and abandoned during review is usually a **`Rejected` entry**, which is a better home for
it than a superseded record, because it names something concrete that failed and why.

**Once a record is `accepted`, the permitted edits are exactly three frontmatter keys** --
`status:`, `superseded_by:`, and `areas:`. The body is never touched. The line this draws:
the freeze protects the *historical claim* (what was believed and decided, which an edit
falsifies), not the *navigation metadata* (which record supersedes this one, what subject to
find it under). Retagging `creds` to `credentials` while merging synonyms in `AREAS.md`
changes nothing about what the decision said; rewriting a sentence does.

### Proposed records ahead of their code

The common case is a record traveling with its own diff: opened `proposed` when the PR
opens, flipped to `accepted` in that same PR, frozen on merge. Nothing below applies to it.

A record may also be **merged to `main` while still `proposed`, with none of its code
written** -- a design agreed as direction, often blocked on defects elsewhere. That is
allowed, because the alternative is a long-lived branch holding the one artifact the team
most needs to read while the blockers clear. It carries three obligations, and they exist
because such a record is a liability in exactly the way an accepted one is not: it describes
a present tense that does not exist, in a directory whose whole premise is explaining code
that does.

- **The freeze does not bind it.** It stays editable, body included, for as long as it is
  `proposed`. This is why the line above is `accepted` and not `main`: a design still under
  discussion must be able to absorb the discussion, and a merged-but-unbuilt record
  otherwise leaves amendment with nowhere legal to go.
- **The landing PR rewrites the body to what shipped, then flips to `accepted`.** Not the
  intent as agreed months earlier -- the mechanism as built, with the divergences moved into
  `Rejected` where they belong. Only that rewritten form is frozen, and only it is worth
  freezing: what is preserved is a belief someone acted on, not one they abandoned on
  contact with the code.
- **`issue:` is required**, and the ticket stays open until the flip. A record on `main`
  reads as settled; the ticket is what says the argument is not.

An agent reading a `proposed` record should treat every identifier in it as **a name for
something that may not exist yet** -- `git grep` the symbol before believing the code
matches the account. The status field is the only thing separating the two, and the prose
of a good record is confident either way.

Two shapes need distinguishing here, because only one of them earns the exception. A design
the team has committed to and cannot yet build is a decision; a design nobody has agreed to
is a proposal, and belongs on its ticket until it is one. The test is whether someone would
object to work being started along these lines, not whether work has started.

## When to write one

Write a record when a change embodied a judgment call: a mechanism chosen over an
alternative, a constraint accepted, a compromise taken knowingly, an ordering or layering
that had a reason, a fix whose *cause* was surprising.

Do not write one for a typo, a rename with no rationale, or a mechanical refactor. Do
write one for a "simple" bug fix whose diagnosis was non-obvious -- that diagnosis is
exactly what is lost otherwise, and it is the cheapest record to write and the most
valuable to find.

When in doubt, write it. The bar is low on purpose.

### Where to write it, when the decision spans repos

**A record lands in the repo whose code it decides.** The retrieval story is `git grep`
inside one clone, so a decision about `app.py`'s lifespan or `PHD2Connector.__init__` is
unreachable from here no matter how well it is written -- an agent working in `MAST_unit`
has no reason to read `MAST_provisioning/docs/decisions/`, and the anchoring rule buys
nothing across a clone boundary.

A design that genuinely spans repos is normal, and splitting it into fragments would destroy
it. Keep it whole in the repo carrying the **larger share of the change**, and add a short
record in each other affected repo -- a paragraph on what changes there and why, naming that
repo's own symbols, citing the full record by slug and repo. The stub is not bookkeeping: it
is the only thing that makes the decision findable from the code it actually constrains.

Until the other repos adopt this format, cite the full record from that repo's `CLAUDE.md`
or its issue instead, and say in the record which repos it reaches.

## Retrieval

    git grep -il '<symbol or path>' docs/decisions/    # symbol -> record (and the archive)
    git grep -l '^  - storage$' docs/decisions/        # every record tagged with one area
    ls docs/decisions/2*.md                            # the index (filenames are slugs)
    grep -l 'status: proposed' docs/decisions/2*.md    # decided but not yet built -- read as design, not as code

`AREAS.md` lists the area terms in use, and carries the command that re-derives them from the
records.

The `2*.md` glob matches records only, excluding this spec file (which contains the field
names as examples, and would otherwise be a false hit in every frontmatter query) and the
archive. Records are always date-prefixed. A `git grep` without the glob is the right
default for content searches, since it reaches the archive too.

There is deliberately **no index of records**. The directory listing is the index, because
the filenames are descriptive slugs; a hand-kept list of records would go stale the first
time someone forgot to update it, and would duplicate what `ls` already shows. Generate one
at build time if a rendered view is ever wanted.

`AREAS.md` is not that: it is a *vocabulary* list, and it holds facts the directory listing
cannot -- which terms exist, and what merged into what. It is also derived before it is
curated (the command lives in the file), so drift shows up as a diff against reality rather
than as quiet rot.

## Relationship to the other surfaces

- **`archive-2026-05-04-to-2026-08-03.md`** (this directory) -- the frozen former
  `DECISIONS.md`, 118 entries, kept whole rather than split. Still authoritative for
  everything it covers and the only place that rationale lives, so search it as well as
  the records. Nothing is appended to it. Roughly 30 comments across the repo still cite it
  by its old root path; the date in those is good, the path is not.
- **`AREAS.md`** (this directory) -- the living list of `areas:` terms, plus the retired and
  merged ones. Consult before tagging a new record; add to it when you coin a term.
- **GitHub issues and PRs** -- carry the discussion, the alternatives argued in real time,
  and the review. They are *not* the final home: they are not in the clone, so an agent
  reading the repo cannot see them. Distill the outcome into a record here.
- **PR bodies** -- carry the per-change *Why* (see `CLAUDE.md`). That covers the common
  case; a record here is for decisions whose rationale should survive independently of the
  diff that carried it.
- **`CLAUDE.md`** -- carries standing rules and gotchas: what to do and not do *now*.
  Records explain how those rules came to be. When a record establishes a rule, add the
  rule to `CLAUDE.md` and have it cite the record.
