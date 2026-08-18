---
decided: 2026-08-18
status: proposed
issue: MAST_provisioning#72
areas:
  - static analysis
  - failure reporting
---

# BLE001 is waived per site, not per file

**Why:** the ruff adoption (#65) waived `BLE001` in six files, which meant those files were exempt **wholesale** -- a new bare `except Exception` in `transport.py`, `run-prov-test.py`, `test-suite.py`, either validation provider or `run-remote-script-winrm.py` landed unremarked. That is not what the repo's own doctrine asks for ("scoped rather than global"), and `driver.py` already showed the better shape: targeted `# noqa: BLE001` with a reason on the line.

**What:** all 34 sites now carry `# noqa: BLE001 -- <what happens instead>`, and `BLE001` is gone from `[lint.per-file-ignores]` entirely. The rule is live in every file. Verified by planting a bare `except Exception` in `transport.py` -- previously waived, now a finding.

**Reading them was the work**, and the result is that the policy this repo actually states was already being met almost everywhere. `~/.claude/CLAUDE.md` says never catch bare `Exception` *without re-raising or logging*; `BLE001` fires on the `except` clause alone and cannot see the handler. Of the 34:

- **30 report**, in four different shapes: they log (`transport.py`'s SSH/WinRM fallbacks, the poller, the diagnostics fetchers), return a failure result carrying the message (`validate_mastrometry`'s `(False, "", "import_failed (...)")`, `test-suite`'s `ScenarioResult(..., ERROR, ..., msg)`), re-raise from a worker thread via a captured `exc[]`, or collect the error for the caller (`transport.py:1145`'s `auth_errors`).
- **4 stay silent**, and the annotation says why on the line: a candidate probe whose loop return value *is* the report; a best-effort `close()` the next request rebuilds anyway; clearing the no-sleep hint on the way out of the process; a diagnostics fetch after a cycle has already been recorded as failed.

**No behaviour changed.** This is deliberate, and it is the difference from the PowerShell equivalent the same day (`2026-08-18-an-ignored-failure-says-so.md`), where 113 empty catches were given a `Write-Verbose`. There, nothing was reporting at all and PowerShell offers a verbose stream that stays out of a normal run. Here, 30 of 34 already report through the mechanism their caller reads, and the remaining 4 sit in loops or exit paths where adding console output would be noise on the operator's screen for a failure that by construction does not matter. `transport.py` has only `_log`, which goes straight to the run log -- there is no quiet channel to put this in.

**Rejected:**

- **Narrowing the exception types.** The reason #72 gave still holds: it means knowing, per site, which exceptions actually arrive from paramiko, pywinrm, `subprocess` and the Windows APIs underneath, and a guess trades a style finding for a run that dies on the one exception nobody predicted.
- **Leaving the file-level ignores and annotating anyway.** Ruff reports `RUF100` for a `noqa` whose rule is not enabled, so the two cannot coexist -- which is how this change proved the ignores were what disabled the rule: all 34 annotations reported `RUF100 (non-enabled: BLE001)` until the waivers came out.
- **A uniform reason.** "Deliberate" is not a reason, and a file-level comment cannot say which of the four reporting shapes a given site uses.
- **Doing C901 in the same change.** The other half of #72, and it is a real refactor: `render` in `fleet-drift-report.py` is at **35**, not the 19 the issue records, and `_process_unit` at 20 is the phase sequence a fleet run walks. Those want their own sitting with the flow tests as the harness.

**Unsettled:**

- **`C901` is still waived per file** in eight entries, with the same blanket problem this change fixed for `BLE001`: a new complex function in `driver.py` or `fleet-drift-report.py` is exempt today. The per-function `# noqa: C901` conversion is the cheap half of that work and could land before the refactors.
- **`S110`, `SIM105`, `SIM115`, `TRY004`, `B904` and `PLW1510` remain file-level waivers** in the `vm/` harness and `transport.py`. Nothing has audited whether they deserve the same per-site treatment; `S110` and `SIM105` in particular overlap with the four silent handlers above.
- **The annotations are only as true as the code around them.** A reason saying "logged below" stops being true if the log line is removed, and nothing checks that -- unlike `RUF100`, which at least catches an annotation whose rule stopped firing.
