---
decided: 2026-08-23
status: accepted
issue: MAST_provisioning#133
areas:
  - providers
  - reproducibility
  - drift
---

# The Jupyter stack is locked, and the lock is what drifts

**Why:** `provide-jupyter.ps1` installed nine unpinned package names, so what a unit got depended on what PyPI served the day it was provisioned. Measured on two units four days apart:

```
mast05 (2026-08-19) vs mast06 (2026-08-23)   117 packages each
identical: 114   differing: 3

argon2-cffi-bindings   25.1.0 -> 26.1.0     (major bump)
pyzmq                  27.1.0 -> 27.2.0
scipy                  1.18.0 -> 1.18.1
```

Four days, three divergences, one of them scipy -- the class of difference that makes two units disagree about a computation. mast01-mast04 were provisioned months earlier and have never been compared.

**Pinning the nine names would have fixed one of the three.** `argon2-cffi-bindings` and `pyzmq` both arrive transitively via `notebook` and appear nowhere in the provider. Only a lock over the full resolved set closes this, which is the thing worth knowing before reaching for `numpy==...`.

**What:**

- `assets/requirements.txt` -- all 118 packages pinned with `==`, from `pip freeze --all` on mast06's freshly built venv under Python 3.12.2, the version `provide-python.ps1` installs. The file's header records where it came from and that refreshing it is a deliberate act with an owner.
- The provider installs with `-r requirements.txt` instead of the inline list.
- It is registered in `module.json` **`commandfiles`**, which is what makes the fleet converge: the per-module content hash covers commandfile bytes, so editing a pin changes the module hash, the driver classifies `jupyter` as `NEEDS_UPDATE`, and an ordinary provisioning run targets it. No `--force`, no per-unit intervention.

**The skip-guard had to change, or none of the above would reach a unit.** It was:

```powershell
if (${Force} -or -not (Test-Path -LiteralPath ${jnExe})) { ...install... }
else { "jupyter-notebook.exe already present; skipping pip install." }
```

A unit that already had Jupyter skipped the install entirely, so a changed pin could never be applied and the fleet could not be converged by re-running provisioning -- the guard would have swallowed the whole mechanism. It now compares the staged requirements' SHA256 against a stamp written into the venv, and installs whenever they differ. This is the shape #129 is about: a guard testing a proxy for success (an exe exists) rather than the state the module is supposed to produce (this exact set of packages).

**The stamp is written only after the install succeeds**, so a failed run cannot convince the next one there is nothing to do -- the failure mode that let a broken ASCOM report `pass` for three days.

**Rejected:**

- **Pinning the direct requirements only.** Cheap, reads naturally, and misses two thirds of the observed drift. The transitive set is where it actually happens.
- **Keeping the exe guard and relying on `--force` to converge.** `--force` runs every module on the unit, so a pin bump would mean a full re-provisioning run rather than one targeted module -- and it would still depend on someone remembering to pass the flag. Drift is the mechanism that already exists for exactly this.
- **A constraints file over the loose names.** Equivalent to a lock for our purposes and leaves two sources of truth about what is installed.
- **Regenerating the lock automatically.** A pin that updates itself is not a pin. Ageing is the cost of reproducibility, and the header says so.

**Unsettled:**

- **The install still needs a package index.** This change makes *what* gets installed deterministic; it does not remove the dependency on reaching PyPI, which has broken this module four times in three days on mast06 through proxy misconfiguration alone. The vendored wheelhouse (`pip download` + `--no-index --find-links`) is the follow-up and lands separately so the size increase is its own reviewable change.
- **mast01-mast06 already differ** and are not converged by this landing. The next provisioning run over each of them will do it, because the lock is drift -- but that is a fleet operation, not something this change performs.
- **Wheels and the lock couple to Python 3.12 / win_amd64.** Today the fleet is uniform because `provide-python.ps1` pins 3.12.2 everywhere. A Python bump means regenerating both, and nothing enforces that pairing yet.
- **The lock was frozen from a unit, not built from a declared intent.** It captures what mast06 happened to resolve to on 2026-08-23, including whatever pip chose for transitive packages. That is a defensible starting point and it is not a considered set.
