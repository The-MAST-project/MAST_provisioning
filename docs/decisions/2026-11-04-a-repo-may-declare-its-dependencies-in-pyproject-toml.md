---
decided: 2026-11-04
status: accepted
issue: MAST_provisioning#242
areas:
  - source-layout
---

# A unit clones MAST_supervision, and a repo may declare its dependencies in pyproject.toml

**Why:** The supervisor (MAST_supervision, `epic:supervision`, #82) is about to be installed on units as a service. No unit can run it until provisioning clones it, and it is the first MAST repo whose dependencies live in `pyproject.toml` rather than `requirements.txt`. `mast-clone` read only `requirements.txt` and `requirements-dev.txt`.

**What:**

- **`tools/mast-repos.tsv` gains a row:** `supervision	MAST_supervision	unit	main`, pinned like every other row. The folder must be named `supervision`, because the repo root is the `supervision` package, imported through the `mast.pth` that already puts `<Top>` on `sys.path`.
- **Role `unit` only**, not `unit,spec` as the issue asked. Spec runs no supervisor until its own stage, and MAST_spec's joint resolve with the supervisor has never been checked. The spec machine's clone is unchanged (team decision, 2026-11-04: unit machines now, spec separately). The spec half is MAST_provisioning#256, which also records that nothing in this repo runs `mast-clone -Role spec` today.
- **A repo with no `requirements.txt` but a `pyproject.toml`** joins the same single `uv pip install` with `-r <dir>/pyproject.toml`: its **runtime dependencies only**. It is still one resolve, so a contradiction between the supervisor's bounds and MAST_unit's pins fails loudly rather than letting the last install win.
- **Its `dev` dependency group is not installed** (team decision, 2026-11-04). The group is the repo's own CI toolchain. Beside the pytest and ruff that already reach every unit through MAST_unit's `requirements-dev.txt`, it carries basedpyright, which pulls a 42 MB `nodejs-wheel-binaries` wheel. That would come through bcproxy onto every unit for a tool nothing on a unit runs.
- **The package roots are named once, in the manifest:** `#!package-roots	common,supervision`, a directive parsed by both halves like `#!uv-version`. The shadowing guard warns when a repo root carries an `__init__.py` (a consumer repo's root would shadow its own module). It now exempts exactly those folders, where it had a hard-coded `common`; without that it would print a false "will shadow" alarm on every run.
- **`verify-mast` expects the new folder:** `-Expect` in `module.json` and the script's default gain `supervision`. A test pins both to the unit role's folders from the manifest, so the next repo added cannot be missed the same way.

**Evidence** (2026-11-04):

- **On the Mac:** `mast-clone.sh --role unit` cloned four repos at their pins and installed in one resolve, with no shadowing warning; `supervision` imports from the checkout. That run predates dropping the dev group.
- **On labcomp2** (Windows PowerShell 5.1, the vendored uv 0.11.33), `mast-clone.ps1 -Update` on a synthetic top with a fake git installed a `pyproject.toml`'s dependencies in the one resolve. It printed no shadowing warning for `supervision`, and flagged a stray `unit\__init__.py`.
- **A joint resolve for Windows / Python 3.12** of the same inputs succeeds under the pinned uv: fastapi 0.140.9, uvicorn 0.51.0, pydantic 2.13.4, psutil 7.2.2, pywin32 312.

**Rejected:**

- **Reading the supervisor's `uv.lock`.** The lock pins the repo's own CI and dev environments. On a unit MAST_unit's exact pins must decide the shared libraries, which is why the supervisor declares lower bounds only.
- **A second `uv pip install` for the pyproject repo.** That is the last-install-wins failure the single resolve exists to prevent.
- **Installing the `dev` group, as `requirements-dev.txt` is for the other repos.** It was built first, with a small TOML probe for whether the group exists. Review found the probe misses valid TOML that uv reads (a trailing comment on the header, `\"dev\" =`, an inline table), dropping the group silently, and that the group is not equivalent to the others' dev files: it carries the Node-backed type checker. Passing `--group` unconditionally would have fixed the first and not the second.
- **Adding `supervision` beside `common` in the guard's hard-coded test.** The next package-root repo would repeat the false alarm. The manifest already carries per-repo facts both halves read.

**Unsettled:**

- **The supervisor does not run against the pinned MAST_common** (`df2669f`): it needs `Const.SUPERVISOR_ACTIONS_PORT`, which is newer. Cloning it is inert, since nothing starts it until the `mast-service` provider exists, and the pin bump that follows this change moves `common` past it.
- **`verify-mast`'s dependency check reads only `requirements.txt` pins,** so the supervisor's one exact pin (`ttkbootstrap==2.2.3`) is not checked on a unit.
- **An existing `mast-unit.code-workspace` is left alone by `mast-clone`,** so units provisioned before this will not show the `supervision` folder in VS Code.

**Implications:** the first run after this touches every unit's `mast` module, because the manifest is in its `repofiles`.
