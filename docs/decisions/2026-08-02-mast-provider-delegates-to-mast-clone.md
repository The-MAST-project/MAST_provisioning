---
decided: 2026-08-02
status: accepted
issue: MAST_provisioning#31
areas:
  - source-layout
  - providers
  - services
  - drift
---

# The mast provider delegates cloning to mast-clone, and unit code lives at `C:\MAST\src`

**Why:** `provide-mast.ps1` carried its own repo list (`mast-repos.txt` +
`mast-repo-list.ps1`), its own clone/pull logic, its own per-repo venv creation
and an unpinned `pip install` -- a second implementation of what
`tools/mast-clone.ps1` already does for the control host and dev boxes, and a
worse one: unpinned resolver, no branch-pin rationale, no `common/__init__.py`
sanity check, and a pull path that `reset --hard`s over local work. Two
implementations of "lay out the MAST repos" is exactly the drift these scripts
exist to prevent (#31).

**What:** The provider now invokes `mast-clone.ps1 -Top C:\MAST\src -Role unit
-Transport https -Update` and keeps only what mast-clone does not do: ensure Git
is present, register the `mast-unit` NSSM service, open the API port, and
restart the service when the unit checkout actually moved (HEAD compared before
and after, so an unchanged cycle does not bounce the service).
`mast-repos.txt`, `mast-repo-list.ps1` and the already-unreferenced
`pull-mast-repos.ps1` are deleted; `tools/mast-repos.tsv` is the only repo
manifest. The scripts reach the payload as the module's `repofiles`.

**The layout changes on every unit.** `C:\MAST\repos\<Repo>\` with a venv per
repo becomes `C:\MAST\src\{common,unit,claude}` with ONE venv at
`C:\MAST\src\.venv`, and `common` resolves via the `mast.pth` mast-clone writes
rather than through the vestigial submodule. All three NSSM coordinates move
(interpreter, entry point, AppDirectory); an already-registered service pointing
at the old interpreter is **re-pointed**, since a pre-migration unit would
otherwise keep running code from a tree stage 6 deletes. `provide-mast-validation.ps1`
and `provide-mast-autofocus-validation.ps1` resolved the unit clone and its venv
by scanning `C:\MAST\repos` for `MAST_unit*`; both now take `-MastTop` and read
the shared venv.

**`verify-mast.ps1` is rewritten content-aware** (#22 stage 4's resolution rule
2, which the plan expected to be the highest-value verify in the set, and is):
HEAD versus the tracked upstream per clone, `pip freeze` versus each repo's
pinned `requirements.txt`, the `common/__init__.py` package check, `mast.pth`
presence, and **a dirty working tree as a failure** -- mast-clone declines to
fast-forward one, so without this a frozen checkout reports healthy forever. A
surviving `C:\MAST\repos` is also a failure: that unit is unmigrated and the
loop must refuse it rather than half-update it.

**Rejected:**

- **Improving `provide-mast.ps1`'s own clone/venv code in place** -- pinning the
  resolver, adding the package check, fixing the destructive pull. Rejected because
  it fixes the copy while leaving two implementations of one job, which is the
  problem #31 exists to remove. Roughly two-thirds of the provider is deleted instead.
- **A venv per repo, as before.** Replaced with one venv per role so a single joint
  resolve covers all of a role's requirements -- two repos pinning the same package
  differently now fail loudly rather than last-file-wins.
- **`PYTHONPATH` for `common`.** `mast.pth` is used instead, because NSSM services
  inherit no shell environment; a path mechanism that depends on a logon session is
  invisible to the thing that actually runs the code.
- **Leaving an already-registered service pointing at the old interpreter.** Rejected:
  a pre-migration unit would keep running code from a tree stage 6 deletes, so the
  service is re-pointed as part of the same change.
- **Letting a unit with a surviving `C:\MAST\repos` provision normally.** Made a verify
  failure instead -- that unit is unmigrated, and half-updating it is worse than
  refusing it.
- **Leaving `verify-mast.ps1` presence-only.** A frozen checkout with a dirty working
  tree would report healthy forever, since mast-clone declines to fast-forward one.

**Unsettled:**

- **This changes the layout on every unit**, and the old tree is not removed here --
  stage 6's migration does that. Until it runs, units carry both trees.
- **The `-Transport https` choice is inherited** from mast-clone's default rather than
  decided here, and interacts with the proxy question that the mast-clone adoption
  raises separately.
- **The record of what was verified is narrow.** Verified on labcomp2, not just
  reasoned about: a real `build-mast.ps1 -Modules mast` staged both repofiles flat by
  leaf name, and appending a line to `tools/mast-clone.ps1` moved
  `module_state.mast.hash` (2a0dd903 -> d3a84caa) with an unchanged `git_sha` -- the
  repofile content drives the per-module hash, which is what makes a targeted update
  select this module. Pester 87/87. What is *not* covered is a real unit migrating
  from the old layout.
- **`verify-mast.ps1` now compares `pip freeze` against pinned requirements**, which
  assumes both repos' `requirements.txt` stay fully pinned. They are today.
