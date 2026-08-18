---
decided: 2026-08-18
status: proposed
issue: MAST_provisioning#72
areas:
  - static analysis
  - drift
---

# render() is a sequence of sections, verified byte-for-byte

**Why:** the first of the two refactors #72 owes. `render` in `tools/fleet-drift-report.py` was 180 lines at complexity **35** -- and it measured 19 when the file-level `C901` waiver went in, so it grew 16 points while nothing could object. That growth is the argument for the refactor as much as the number is.

**What:** nine module-level `_render_*` helpers, each self-guarding and returning `list[str]`, and `render` reduced to the order they run in:

```python
lines += _render_fleet_summary(cols, reference, cmp, boot)
lines += _render_repos_oneliner(repos)
lines += _render_module_matrix(cmp, ok_cols)
lines += _render_tier2(cmp, ok_cols)
lines += _render_drift_detail(cmp)
lines += _render_repo_matrix(repos, ok_cols)
lines += _render_bootstrap(units, boot, repo_boot_v)
lines += _render_result(units, cmp, boot, repos)
```

`render` now states the ORDER and nothing else, which is the only decision it was ever making. Complexity is under 10 with the `# noqa: C901` deleted, and every extracted helper is under 10 as well.

**The output is pinned byte-for-byte, and that came first.** `server/prov/tests/data/fleet_report_golden.txt` holds the exact output of the *pre-refactor* `render` for a fixture that reaches every section it can emit -- a reference column, a drifted unit, an in-sync unit, an unreachable unit carrying an error, tier-2 results both present and never-run, repo divergence with an unhonoured pin, all three bootstrap states, all three RESULT lines. The test was committed passing against the old code, so it is a baseline rather than a description of the new one. The refactor then had to reproduce it exactly, down to the trailing padding in the module and repo matrices.

That matters because the report *is* the operator interface. "The tests still pass" would not have caught a column shifting by one space; a golden does.

**Reading it first corrected the plan.** The design was going to thread three accumulated problem lists out of the helpers as `(lines, problems)` tuples. In fact `module_problems`, `boot_problems` and `repo_problems` are computed at the very end and consumed only by the final section -- as are `host_w` (section 1) and `cur` (bootstrap). Only `cols` and `ok_cols` are genuinely shared, so every helper is a pure function of its arguments and no tuple-threading was needed.

**Module-level functions rather than a `_ReportBuilder` class** (Eli, 2026-08-18). The alternative held `lines`, `host_w`, `ok_cols` and the problem lists as instance state and read more nicely at eight sections, but the state turned out to be almost entirely section-local, so the class would have been holding fields for one method each. Pure functions also stay individually testable, which suits a tool whose whole output is already golden-tested.

**Rejected:**

- **A dispatch table or a list of section callables.** Would make `render` a loop, but the helpers take different arguments and the ordering is the one thing worth reading in that function. A table hides it in data.
- **Normalising the golden** (stripping trailing whitespace, collapsing runs of spaces) to make it easier to maintain. That would hide exactly the class of change the test exists to catch -- the matrices are column-aligned with `ljust`, so padding IS the format.
- **An inline triple-quoted golden** rather than a data file. The matrix rows carry significant trailing padding and `W291` would argue with it forever.

**Unsettled:**

- **The golden's coverage is only as good as its fixture.** Every section is reachable from it today; if a new section is added behind a condition the fixture does not meet, the golden will pass while covering nothing new. Nothing warns about that.
- **`_render_repo_matrix` still carries two branches of its own** (`any_data` vs `total_count == 0`) and delegates its warnings to a tenth helper. It is under the threshold but it is the least tidy of the nine.
- **`main` in the same file is still at 13** and annotated. The argparse-branching argument covers it, but it also assembles the arguments these helpers take, so it is the next thing to grow.
