---
decided: 2026-08-31
status: accepted
issue: MAST_provisioning#131
areas:
  - failure reporting
  - providers
  - reproducibility
---

# virtualenv is dropped, not checked: the last PyPI fetch leaves provisioning

**Why:** `provide-python.ps1` installed `virtualenv` with pip, discarded the result, and exited 0. `*>$null` swallowed every stream and `$LASTEXITCODE` was never read, so a pip that could not reach an index was indistinguishable from one that succeeded. Its own verification block computed the right answer -- `& ${pythonExe} -m virtualenv --version` -- and reduced a failure to `Write-Warning`. And the `module.json` `verify` one-liner ran that same command, piped it into the log, and then reached `Set-Content ... 'python_ok'` whatever it returned; the only failure path was `python.exe` itself being absent. On mast06 the module reported success in two consecutive runs with `virtualenv` absent, and the absence surfaced two modules later as a `jupyter` failure, attributed to jupyter. Three logs to find that the real defect was upstream and had reported success.

The idempotency guard was the one part that was right: it tested Python present **and** `virtualenv` runnable, and correctly refused to skip. So the provider was stricter about deciding whether work was needed than about whether the work succeeded -- the inverse of the `ascom` case in #129, and arguably the more surprising direction.

**What decided the disposition was not the checks but the network.** `pip install virtualenv` was believed, on a sweep of the providers at the time, to be the last PyPI fetch left in a provisioning run: `provide-jupyter` installs its 118 packages `--no-index --find-links` from a vendored wheelhouse and throws if it is not staged, `mast-clone` vendors a checksum-verified `uv.exe` rather than taking latest from a CDN, and #123/#124 replaced the Features-on-Demand payload fetches with shipped assets. So hardening the checks alone would have made things worse before better: mast06 is a bench unit, the order-100 soft proxy module clears the proxy when bcproxy is unreachable, and the bench VLAN has no route to PyPI. Checking the result turns currently-"passing" bench runs into failing ones **with no local remedy** -- the opposite of #175, where a loud failure was actionable because an operator could fix the route. A failure nobody can act on is a worse deliverable than the silence.

**What:** the failure is removed rather than reported.

`virtualenv` is gone in favour of the stdlib `venv` module, which Python 3.12 ships: no install, no network, no vendored wheel. It had exactly one consumer in the repo, `provide-jupyter.ps1`, whose venv creation already contained a fallback to `python -m venv` -- and that fallback was dead code, because `Invoke-Native` throws on a non-zero exit and so a missing `virtualenv` killed the provider before reaching it (#130). Jupyter's creation step collapses to a single `python -m venv`, and #130 closes by deletion: with `virtualenv` gone there is nothing left to fall back from.

The pip *upgrade* goes too. Its own comment called it "optional but good practice"; it was a second network fetch buying nothing this provider needs. `ensurepip --default-pip` stays, because jupyter's `--no-index` install still needs pip, and **its result is now checked**.

**Existing installs are actively removed, not merely left behind:** `pip uninstall -y virtualenv` when `pip show virtualenv` finds it. Uninstalling needs no network, so it is safe on an offline unit, and it is scoped to the system Python at `C:\Python312`. `virtualenv` is not in jupyter's locked `requirements.txt`, so no wheelhouse change and nothing to remove from the venv. Existing jupyter venvs built by `virtualenv` are left alone -- one works fine, and `provide-jupyter` skips creation when the venv is present.

**The idempotency guard had to be restructured for that, and it is the subtle part.** The guard exits 0 early when the end state looks right, so a unit that already had Python + pip + `venv` would skip the whole provider and never run the cleanup -- `virtualenv` would survive forever on exactly the units that have it, which is every unit provisioned to date. The guard now tests four clauses, the fourth being that `pip show virtualenv` reports **nothing**, and the installer is skipped independently of it: an existing Python is left alone while the pip chain, the removal and the assertions still run. This is #129's pattern (a guard testing something weaker than what the module actually produces) and it would have been an easy one to reintroduce while fixing its sibling.

`module.json`'s inline `verify` becomes a real `verify-python.ps1`. It asserts the **outcome**, not presence: a throwaway venv is created under `$env:TEMP`, confirmed to yield a `Scripts\python.exe`, and removed -- because that is the capability `provide-jupyter.ps1` consumes, and "`python -m venv --help` exits 0" is a weaker statement than "a venv comes out". It also asserts `virtualenv` is absent, and records `python_version` through `Write-MastModuleFacts` so the fleet report carries which Python each unit is on.

The module description is corrected in the same change. It claimed *"Pinned to mastw/mast00"*, but no host sets `modules` in `server/unit-registry.json`, so this module runs on every unit -- it misstated its own blast radius.

Four pytest guards land in `server/prov/tests/test_provider_failure_reporting.py`: no `*>$null` call in `provide-python.ps1` without a following `$LASTEXITCODE` read, no `pip install virtualenv`, a `pip uninstall` that is present *and* an early-exit guard that checks `pip show virtualenv` before it, and a python `verify` that is a script rather than an inline `-Command`. Fixing them exposed that the module's own `_LASTEXITCODE` pattern matched only the bare `$LASTEXITCODE` spelling and not `${LASTEXITCODE}`, which the providers use freely; it now matches both, and no existing provider fails the widened check.

**Rejected:**

- **Hardening the checks and keeping `virtualenv`.** The straightforward reading of the issue, and what its title asks for. Rejected on the network finding above: it converts a silent pass into a failure a bench operator cannot clear, on the one provider still reaching the internet mid-run.
- **Vendoring the `virtualenv` wheel and installing it `--no-index`, as jupyter does.** Also offline-correct, and the smaller conceptual change. Rejected because it keeps a dependency whose only use in the repo was a dead fallback path, and adds a wheel to keep pinned and refreshed for it.
- **Leaving existing `virtualenv` installs in place.** The narrower change: stop installing it, let the fleet age out. Rejected on Eli's requirement that the units converge -- an unremoved package is indefinite drift between what the provider produces and what the units carry, and the removal costs one `pip uninstall` with no network.
- **Letting the guard skip the cleanup and running the removal as a one-off fleet migration.** Rejected because it puts a permanent invariant (`virtualenv` is not installed) into a temporary vehicle, and the guard would still be weaker than what the module produces.
- **Widening the discarded-result audit to all ~22 providers in this change.** That is #62 axis 2 and deserves its own pass; bundling it would hide this disposition in a sweep.

**Unsettled:**

- **"The last PyPI fetch" is a claim about the state of the providers on 2026-08-31, established by reading them, not by watching a run's traffic.** If another provider fetches from an index in a path that was not read, the argument that hardening had no local remedy is narrower than stated -- though the disposition for *this* provider would not change.
- **Nothing here is verified on a unit yet.** The pytest guards are static, and the plan's VM runs -- `--modules python` with an unresolvable machine-scope proxy passing (the evidence that the fix removed the failure rather than reporting it), a deliberately broken install failing, and `--modules python,jupyter` end to end on a unit that starts *with* `virtualenv` present so the cleanup path is exercised -- have not been done. In particular the throwaway-venv assertion in `verify-python.ps1` has never run under real Windows PowerShell 5.1.
- **`execute-mast-provisioning.ps1` never refreshes its env block from the registry,** so machine-scope variables written by the order-100 proxy module are invisible to this order-600 provider in the same run -- providers are children of the long-lived execute process. `provide-mast.ps1` carries a hand-rolled `Update-MastProcessPathFromRegistry` for its own version of this. That is #43's family (PATH staleness within a run, with proxy variables instead of PATH) and is very likely why mast06's pip could not reach an index even on a run where the proxy had been configured. It is left there deliberately; this change makes it moot for `python` by removing the fetch, and does nothing for whoever meets it next.
- **The removal is one-directional and unguarded against a reinstall from outside provisioning.** `verify-python.ps1` fails a unit where `virtualenv` reappears, which is the alarm, but nothing prevents a technician's `pip install` from putting it back between runs.

**Implications:** a `python` module run on a unit with no route to PyPI now succeeds honestly rather than passing silently, and a `jupyter` failure two modules later no longer has this as a hidden cause. Every unit provisioned before today loses `virtualenv` on its next cycle. #130 closes with no code of its own. The `python` module gains its first entry in the fleet report's module-facts table (`python.python_version`), which needs no report-side change -- facts are namespaced per module.
