---
decided: 2026-09-01
status: accepted
issue: MAST_provisioning#180
areas:
  - providers
  - reproducibility
---

# The Jupyter wheelhouse's interpreter pin is enforced by the build, not documented

**Why:** #133 locked the Jupyter stack and vendored its 118 wheels, which was correct and did what it claimed — but it silently took a dependency on a version that lives in another module. Fifteen of those wheels are `cp312-cp312-win_amd64`, bound to CPython 3.12 exactly; the interpreter is declared in `server/providers/python/module.json` (`"version": "3.12.2"`, with the matching installer in that provider's `commandfiles`). Bumping Python is a small, local-looking edit in the `python` provider that invalidates wheels in the `jupyter` provider, and nothing in the repo connected the two. That was recorded under **Unsettled** in the 2026-08-23 decision (*"A Python bump means regenerating both, and nothing enforces that pairing yet"*) and listed as item 3 of what #133 should settle; #133 closed without it.

The failure direction is right — the provider installs `--no-index --find-links`, so a mismatched interpreter finds no candidate rather than resolving to something different, and the module fails loudly. What is wrong is *when* and *how widely*: the first detection is a failed provisioning run on a real unit, every unit fails the same way, and nothing on the unit can remedy it.

This class has already bitten once. `build/build-mast.ps1` pins cygwin to 3.6.9 "matching the bundled fitsio wheel tag" because the rolling itefix mirror moved past it and broke the pinned wheel (#20). Same shape, and there it is still a comment rather than a check.

**What was decided:** the coupling is asserted on the build host, where both declarations are visible and a mismatch costs seconds.

- `Get-MastWheelInterpreterMismatches` in `build/build-staging-lib.ps1` compares wheel filenames against a declared `major.minor`. Three tag families, three rules: `py3-none-any` is ignored; `cpXY-abi3-<plat>` treats `cpXY` as a **minimum** (the seven abi3 wheels in the tree declare cp37..cp312, all satisfied by 3.12); `cpXY-cpXY-<plat>` must match exactly. It reads filenames only — no file content, so it works against LFS pointers and needs no Python on the build host — and it returns reasons rather than throwing, which is what makes it testable without a build. Thirteen Pester cases cover it, one of them asserting the real 118-name wheelhouse against 3.12.2.
- `Assert-JupyterWheelhouseInterpreterInSync` in `build-mast.ps1` is the thin wrapper, following the two existing bootstrap guards in name, placement and success log line. It reads the `python` module's declared version as authoritative, and reads it out of its own `-ProvidersRoot` argument rather than through `Read-ModuleManifest`: that helper takes its root from a script-scope `$providersRoot`, which PowerShell resolves up the dynamic scope chain and case-insensitively, so called from inside a function holding a `$ProvidersRoot` *parameter* it lands on the parameter. Same value during a build, and a silent coupling — found when the guard could not be pointed at a test root. Everything the guard reads is now its argument.
- **It runs when *either* module is staged, not only `jupyter`.** The edit that breaks the pairing is a version bump in the `python` provider, and a `--modules python` build would otherwise ship a new interpreter to a unit whose Jupyter venv was built from the old wheels. The check reads the two declarations rather than the payload, so it costs nothing on a build that stages neither's assets.
- An **empty** wheelhouse is deliberately outside this guard: it is already caught where it matters, by the staging throw that refuses to build a `jupyter` payload with no wheels. Here it is vacuously in sync.
- `provide-python.ps1` no longer carries a second copy of the version in its install log line; it names `${Installer}` instead, so the log cannot disagree with the artifact.

**Rejected:**

- **Single-sourcing the version so the mismatch cannot be authored.** Regenerating 118 wheels for a new interpreter is a `pip download` on a Windows host running the fleet's Python — a deliberate act with an owner, per the header of `requirements.txt` (which is also why the lock is what drifts). A build cannot perform it, so a build cannot make the pairing automatic. The assert does not pretend otherwise: it makes forgetting impossible to ship, which is all that was asked for.
- **A unit-side verify.** Later and fleet-wide, which is the cost being removed.
- **Generalizing to cygwin/fitsio (#20) in the same change.** The helper would take it, but folding it in turns a bounded guard into a sweep. Left as a follow-up, with the shape in place.

**Implications and known boundary:**

- A deliberate Python bump now fails the build until both artifacts are regenerated. That is the intent, and the throw carries the regeneration command and the reason.
- **The guard trusts `module.json`'s `version` and nothing checks it against the installer that actually runs.** `provide-python.ps1` installs whatever `-Installer` names (defaulting to `python-3.12.2-amd64.exe`, staged via `commandfiles`), so a `version` edited without the asset — or the reverse — would have the guard comparing wheels against a version the unit does not receive. Closing that is the same class of check and is deliberately not in this change.
- Non-`cp` tags are silent by design: `py3`, `py2.py3` and a PyPy `pp310` carry no CPython-version constraint. If a PyPy wheel ever enters the wheelhouse, that silence becomes a gap rather than a correctness statement.
