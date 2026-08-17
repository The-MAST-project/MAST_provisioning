---
decided: 2026-08-17
status: proposed
issue: MAST_provisioning#87
areas:
  - static analysis
  - reproducibility
  - platform independence
---

# Pyright, not mypy, gates the Python server -- and it lands green

**Why:** `ruff` gated style and a Pyflakes-level slice of correctness, and nothing checked types. `server/prov/` was already 88% annotated on returns (97 of 110 `def`s) with nothing enforcing any of it. Both checkers were run against `f838188` before choosing, and the findings were not style: an unchecked `Popen` pipe dereference in `vm/test-suite.py`, five `None` dereferences, eleven sites where `prov.transport.load_json_file()`'s `object` return was iterated, indexed and `.get()`-ed anyway, and a parameter annotation on the SSH retry wrapper that has been wrong since SSH became the default transport.

**What:** basedpyright 1.39.10 (pyright 1.1.412 plus a stricter default rule set) pinned in `requirements-dev.txt`, configured by `pyrightconfig.json` at the repo root, run by a fourth `.github/workflows/ci.yml` job named `types`. Fifty findings cleared in this change; the transport session model deferred to stage 2 of #87.

**The measurement, since the two tools disagree about what this repo contains:**

| Run | Errors | Files |
|---|---|---|
| mypy 2.3.1, defaults | 20 (17 net of unit-side imports) | 7 |
| mypy + `check_untyped_defs` + `follow_untyped_imports` | 40 | 11 |
| basedpyright, `standard`, `pythonPlatform: All` | 50 (47 net) | 10 |
| basedpyright, its default `recommended` mode | 135 errors + 2508 warnings | -- |

Four reasons for pyright. **mypy's exclusive advantage does not apply here:** its plugin system (pydantic, django-stubs, sqlalchemy) is the usual argument for it, and this repo uses no such framework -- the 7 frozen `@dataclass`es in `prov.drift`, `prov.maintenance_window`, `prov.proxy_assert`, `prov.staging_size` and `prov.winrm_flap` are native to both. **The test suites are unannotated,** so mypy's default declines to check their bodies (it says so three times, `annotation-unchecked`); pyright checked them and found the `_FlakySsh`/`_StuckSsh` fakes in `server/prov/tests/test_transport.py` being passed where `winrm.Session` is declared. **Pylance already runs pyright in the editor,** so `pyrightconfig.json` makes CI enforce what is on screen, in one dialect of suppression comment rather than two. And **`pythonPlatform: "All"` checks the Windows and POSIX branches in a single pass** -- mypy needs two `--platform` runs, in a repo whose whole point is a Linux-target server driving Windows units.

**The discriminating finding.** `_resilient_run_ps(session: winrm.Session, ...)` in `server/prov/transport.py` calls `session.run_ps(script, timeout_s=timeout_s)`. pywinrm's `Session.run_ps` has no `timeout_s`, and under SSH-first the object that arrives is an `SshSession`. pyright reports it. mypy synthesizes an intersection type at the `isinstance(session, SshSession)` guard and accepts it silently, complaining only at the test call sites and only with `check_untyped_defs` on. Neither `ruff` nor the 404-case test suite could see it, because the tests exercise the SSH path where the call is correct.

**What the 50 turned out to be.** Six root causes, not fifty defects:

- **`load_json_file() -> object`, 15 findings.** Two typed wrappers now sit beside it: `load_json_object() -> dict[str, Any]` and `load_json_list() -> list[dict[str, Any]]`, both raising `TypeError` naming the path when the top-level shape is wrong. The five typed call sites in `prov.driver` and `prov.transport.load_creds` use them; `vm/test-suite.py` keeps the raw primitive and validates its own result. A malformed unit registry now fails at load rather than at the first `entry.get(...)` -- or, worse than either, provisioning nothing and reporting a clean run.
- **`git_sha` / `payload_hash` Optionals, 12 findings.** `_build` read both with a bare `bm.get(...)`. `git_sha` absence is `""` (matching the `_process_unit` seed and `logevents.activity()`'s own default); `payload_hash` keeps its `None` sentinel, which `_process_unit` reads as BUILD_FAIL, so the narrowing is done once into a new `built_hash` local and `_build` now returns `tuple[str | None, str, dict[str, Any]]`.
- **`Transport | None`, 2 findings.** `paramiko`'s `get_transport()` returns None when the client is not connected. A named `_require_transport()` guard raises `ConnectionError` -- the same class raised on a mid-command drop, so `_resilient_run_ps` reconnects and retries rather than dying on an `AttributeError`. It is a module-level helper rather than two lines inside `SshSession.run_ps` because that method was already at ruff's C901 threshold and the guard pushed it to 11.
- **The `importlib.util.spec_from_file_location` idiom, 6 findings.** `assert spec and spec.loader` in the three test bootstraps.
- **Five genuine `None` dereferences** in `vm/test-suite.py` (the `_reader` closure holds `proc.stdout` past a narrowing that does not survive into another thread), `vm/run-prov-test.py` (the log poller's `_session`, now explicitly `Any`, and `unit_session` in the cycle loop) and `tools/fleet-drift-report.py`.
- **Three unit-side imports** (`common.config.local`, `PlaneWave.ps3cli_locate`, `focus_analysis`) that only resolve on a unit, suppressed at the import line where the two provider scripts already did the same for their siblings.

Four `# type: ignore[import]` comments went with them: pywinrm 0.5.0 and requests both ship `py.typed`, so they were no-ops -- and they used mypy's error-code syntax, which pyright reads as a blanket suppression of everything on the line.

**It lands green and blocking,** on the reasoning in `2026-08-11-ci-is-three-jobs-and-lands-green.md`: a permanently-red check stops being read, which is the failure #55, #67, #68 and #69 all describe. What is deferred is line-scoped with a reason at each site, the way `ruff.toml` scopes C901 and BLE001, so the rule stays blocking everywhere else and new code cannot add to the pile. And the gate was seen to fail before being trusted -- a planted `return n` from a `-> str` function exits 1, its removal exits 0 -- which was listed as unsettled for the `pester` and `lint` jobs when they landed.

**Rejected:**

- **mypy at its defaults.** 20 findings, reaching neither the test suites nor the transport annotation defect, with a plugin advantage worth nothing here.
- **mypy tuned to parity** (`check_untyped_defs`, `follow_untyped_imports`, plus `types-paramiko` as a new dev dep). Reaches 40 and still misses the call-site defect, and means a second rule set and a second suppression dialect alongside the pyright Pylance is already running.
- **Running both.** Defensible on paper; in practice it spends review attention on findings that are one tool's philosophy rather than a bug, and doubles the suppression comments in the same files.
- **basedpyright's default `recommended` mode**, and the `reportUnknown*` / `reportAny` families with it. 2508 warnings is a rule-selection argument to have separately, once `standard` is green and holding. `typeCheckingMode` is therefore set explicitly rather than inherited.
- **Landing red as visible debt**, as MAST_common and MAST_unit did with ruff. Same rejection as in the CI record, on the same evidence.
- **`ignore`-globbing `server/providers/**`.** Cheaper than three suppression comments, and it would blind the checker to two scripts that only ever execute *on a unit* -- exactly where a type error surfaces during a production run instead of at review.
- **`-> Any` on `load_json_file`.** One line, kills all 15 findings, and re-blinds every call site: precisely the state mypy was in via the `# type: ignore[import]` comments.
- **Narrowing inline at each `load_json_file` call site** instead of adding the wrappers. No API change, but ~15 lines of narrowing inside `_process_unit` that a `UnitEntry` TypedDict (stage 3 of #87) would then throw away.
- **A `types` step inside the existing `lint` job.** It would keep one job, and it would both mix two signals and force the lint job to install the runtime deps it currently does not need.

**Unsettled:**

- **The `types` job has been seen to pass on a runner, not to fail on one.** It ran green in 20s on its first Actions run (#88), so unlike the `pester` and `lint` jobs at their landing it is no longer only YAML. The planted-error check -- a `return n` from a `-> str` function, exit 1, and exit 0 on its removal -- was run locally only, so what is unverified is the runner's *failure* path: that a real type error turns the check red in Actions rather than, say, being swallowed by a missing dependency that makes `basedpyright` exit 0 on zero files.
- **`reason_by_outcome` and `note_by_rc` in `prov.driver._transfer` are annotated `dict[Any, str]`.** The keys come from a unit's `PULLRESULT` JSON, so a missing or garbled marker must land on the default rather than raise. Typing the marker payload properly is the same work as the `UnitEntry` TypedDict and belongs with it; the annotation is honest about the boundary but it is an `Any` at a boundary all the same.
- **`load_json_list` rejects a `null` registry** where the old `or []` tolerated it. That is deliberate -- a provisioning server that silently provisions nothing is the failure mode this repo keeps re-finding -- but no test covers a registry file containing `null`.
- **Nothing checks that `pyrightconfig.json` and `ruff.toml` stay in step** on `pythonVersion` / `target-version`, or that either stays in step with the CI matrix's `python-version`. Three places name 3.12.
- **The `# type: ignore` comments left in the two provider scripts are blanket**, not rule-scoped. Pyright's scoped form is `# pyright: ignore[reportMissingImports]`, but these files are also read by whatever the units run, and a mypy-syntax comment there is harmless where a pyright-syntax one would be unfamiliar. Not converted; not obviously right either way.
