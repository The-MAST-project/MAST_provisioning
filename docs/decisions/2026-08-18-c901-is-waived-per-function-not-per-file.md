---
decided: 2026-08-18
status: proposed
issue: MAST_provisioning#72
areas:
  - static analysis
  - rationale retrieval
---

# C901 is waived per function, and the two refactors it was hiding are now visible

**Why:** the same blanket problem `BLE001` had until this morning (`2026-08-18-ble001-is-waived-per-site-not-per-file.md`). `C901` was waived in eight files, so `driver.py`, `fleet-drift-report.py`, the flow tests, the `vm/` harness, `run-remote-script-winrm.py` and both validation providers were exempt **wholesale** -- a new complex function in any of them landed unremarked.

That is not theoretical. **`render` in `fleet-drift-report.py` grew from complexity 19 to 35 while its file was exempt.** #72 recorded 19 when the waiver went in; measuring it today gives 35. Nothing objected, because nothing could.

**What:** all ten over-threshold functions carry `# noqa: C901 -- <why>`, and `C901` is gone from `[lint.per-file-ignores]`. Proven armed by planting a complexity-11 function in `driver.py` and watching it fail.

The ten split three ways:

- **Six argparse `main()`s** (12 to 25). The branching *is* the CLI surface. Splitting buys nothing; a dispatch table would be a design change, not a cleanup.
- **Two that are the thing they emulate.** `make_responder` in the flow tests is a fake with one branch per remote command it answers; `validate_series` has one branch per outcome a focus series can produce, where the branches *are* the assertions. `emit_guest_mast_lines` is a third of this kind -- one branch per `##MAST##` line shape, and splitting would scatter one format across six places.
- **Two real refactors, still owed** (#72): `_process_unit` at 20 and `render` at 35. Their annotations are placeholders that name the ticket, and each is deleted by the change that splits it.

**Annotating first, refactoring second, is the point of the sequencing.** The rule is live today, so nothing new can be added to either pile while the refactors wait -- and each refactor becomes an independent, revertible change whose diff is "split this function, drop one annotation" rather than a lint-config negotiation.

**What the two refactors will need**, recorded now while the survey is fresh:

- **`render`** is 180 lines of pure string building into a `lines[]` list, sectioned by literal headers. Extract one function per section. Lowest-risk refactor in the repo -- no side effects, and `test_csv_and_text_report_agree` already pins that the text and CSV reports cannot diverge. A golden-output snapshot before touching it makes it verifiable rather than merely tested.
- **`_process_unit`** is 267 lines with roughly nine early `return`s, each meaning "stop this unit, for this reason" (unreachable, already current, no drift, dry-run stop, outside the maintenance window, lease held). Extracting phases means each extracted method must be able to stop the unit, so the shape is one method per phase returning a continue verdict, with `_process_unit` left as a legible sequence of guarded calls -- deliberately not a phase table and not a control-flow exception, because the ordering is the contract and should stay readable as code. Its harness is strong: 26 flow tests assert on the emitted event stream, including events that must NOT appear. Snapshot the full event sequence per fixture as a golden first, require byte-identical output after, and run a VM cycle before merge, since this is the path a fleet run walks.

**Rejected:**

- **Refactoring in this change.** Two functions totalling 447 lines, one of them the orchestrator's spine, at the end of a day that already shipped four other PRs. That is how a real regression is introduced for a style score -- the reason #65 deferred it in the first place.
- **Removing the annotations from the six `main()`s by refactoring them too.** Ruff counts argparse branching as complexity; the CLI is genuinely that shape. The annotation is the honest answer, not a placeholder.
- **Closing #72 here.** It is what the ticket is about -- nothing is hidden any more -- but the two refactors are still owed and the ticket carries them (Eli, 2026-08-18).

**Unsettled:**

- **`S110`, `SIM105`, `SIM115`, `TRY004`, `B904`, `PLW1510` and `E501` remain file-level waivers** in four entries. Nothing has audited whether they deserve per-site treatment; `S110`/`SIM105` overlap the four silent `except` handlers annotated this morning.
- **A `noqa` reason can go stale silently.** `RUF100` catches an annotation whose rule stopped firing, but nothing catches one whose *explanation* stopped being true -- if `render` is split into six functions and one still trips the rule, the inherited reason may describe the old shape.
- **`validate_series` (12) and `emit_guest_mast_lines` (11) are marginal.** Both are annotated rather than split, on the argument that their branches carry meaning. That argument would not survive either function growing much further, and nothing marks the line.
