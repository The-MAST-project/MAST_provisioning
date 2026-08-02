# MAST Provisioning - Architecture Decisions

---

## [2026-08-02] The mast provider delegates cloning to mast-clone; unit code lives at C:\MAST\src

**Why:** `provide-mast.ps1` carried its own repo list (`mast-repos.txt` +
`mast-repo-list.ps1`), its own clone/pull logic, its own per-repo venv creation
and an unpinned `pip install` -- a second implementation of what
`tools/mast-clone.ps1` already does for the control host and dev boxes, and a
worse one: unpinned resolver, no branch-pin rationale, no `common/__init__.py`
sanity check, and a pull path that `reset --hard`s over local work. Two
implementations of "lay out the MAST repos" is exactly the drift these scripts
exist to prevent (#31).

**What:** the provider now invokes `mast-clone.ps1 -Top C:\MAST\src -Role unit
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

**Verified on labcomp2, not just reasoned about:** a real
`build-mast.ps1 -Modules mast` staged both repofiles flat by leaf name, and
appending a line to `tools/mast-clone.ps1` moved `module_state.mast.hash`
(2a0dd903 -> d3a84caa) with an unchanged `git_sha` -- the repofile content drives
the per-module hash, which is what makes a targeted update select this module.
Pester 87/87.

---

## [2026-08-02] The GitHub token is deleted, not re-plumbed

**Why:** `provide-mast.ps1` cloned with a PAT embedded in the remote URL
(`https://x-access-token:<tok>@github.com/...`), read from a `mast_github.txt`
staged into the payload. That left a live secret in plaintext in every
provisioned unit's `.git/config`, and one copy of the token file per run under
`C:\mast-staging\<run-id>\` -- issue #17. Every repo the module clones is now
**public** (verified 2026-08-02 across all seven The-MAST-project repos), and
`provide-mast.ps1` was the token's only consumer, so the credential is not
needed by anything.

**What:** removed the credential rather than managing it better. Gone:
`Get-MastGitHubHttpsCloneUrls` and the token read in `provide-mast.ps1` (clones
are anonymous HTTPS via a plain `Get-MastGitHubCloneUrl`); the
`vault\tokens\mast_github.txt` staging copy, the `-AllowMissingGithubToken`
switch and its `-TestMode` optional-payload exception in `build-mast.ps1`; the
switch at all three call sites (`check-and-provision.ps1`, `prov/driver.py`,
`vm/run-prov-test.py`); and the setup step, vault-tree entry and requirements
Exception #3 / row 12 in the docs. The `.gitignore` rules for the token are
deliberately **kept** as a guard against re-introduction.

**Implications:** a dev/test build no longer needs a credential to exercise the
`mast` module, which removes the last reason `-TestMode` differed from a
production build on secret material. This reverses only if a MAST repo goes
private again -- and then via an org-scoped `url.<...>.insteadOf` rewrite or a
credential helper, **never** a token baked into a remote URL. Note that expiry
alone would not have broken the current path: GitHub ignores invalid credentials
on a public repo (verified by `git ls-remote` with a bogus token), so the removal
is hygiene, not an outage fix. #17 closes when the stage-6 migration deletes
`C:\MAST\repos` from the units, taking the old tokenised `.git/config` with it.

---

## [2026-08-02] Smoke gates only what ran; report and driver share one set of unit paths

Second and final batch of #33 review fixes; follows the entry below.

**Why:** (1) Phase 9 checked smoke markers for the unit's FULL module set with no
freshness check, which targeting made wrong in both directions. Markers live in a
persistent directory and are only rewritten by the module that runs, so an
untargeted module "passed" on a marker from an older payload -- assurance the gate
had not earned. Worse, a module whose marker went missing (logs cleaned) failed
the unit permanently: drift never targets it because its hash matches, so execute
never regenerates the marker and there is no path out. (2) `write_csv` still read
`module_versions` after the matrix moved to hash-keyed statuses, so one run emitted
a text report saying STALE and a CSV showing no drift -- and this very PR's
desktop-shortcuts change (verify command gained `-FastApiUrl`, no version bump) is
exactly that case. (3) The unit-side `validation.json` path was spelled in both the
driver and the tool. (4) `_build_manifest` was per-unit state on the long-lived
`Driver`. (5) `load_reference` lost its last caller.

**What:** (1) Smoke asserts over `target_modules or modules` -- what this run
actually executed. Absence of a marker for an untouched module is not a health
signal; the computed tier-2 verify is what answers that. (2) `write_csv` emits the
same cells `render` does, read off `cmp["matrix"]`. (3) New dependency-free
`server/prov/unit_paths.py` holds the shared unit-side literals; the driver and
`tools/fleet-drift-report.py` both import it. It imports nothing on purpose --
the report runs with no third-party deps in `--from-json` mode and must not pull
in `prov.transport` (paramiko/pywinrm) to learn a path. (4) `_build` returns the
manifest as a third element and the caller keeps it local, like `target_modules`.
(5) Deleted.

**Implications:** the fleet report gained its first tests
(`server/prov/tests/test_fleet_report.py`, loaded by path since the tool is a
hyphenated script) covering `compare_to_build`, the CSV/text agreement, both
manifest shapes, and tier-2 parsing -- all previously uncovered. Suite is 125
pytest, up from 106 before the review.

---

## [2026-08-02] Drift review fixes: classify before the hash gate, always-run modules, tier-2 staleness

**Supersedes** parts of the earlier 2026-08-02 entry "Per-module drift decides
what runs; two tiers, one classifier" -- three defects found reviewing #33 before
it merged.

**Why:** (1) The tier-2 `needs-repair` verdict was **unreachable for the case it
exists for**. The unit publishes an aggregate `payload_hash` only when it is
fully provisioned -- every module hash-matched and clean -- which is exactly the
state a runtime failure arises in (payload unchanged, service died). The driver
compared that hash first and returned `already_current`, so `classify()` never
ran and `validation.json` was never read. (2) Targeting by module name **dropped
the order-terminal providers**: `execute-mast-provisioning.ps1` filters commands
strictly by module, so a `-Modules zwo` run skipped `reboot` (order 9999),
`mast-services-finalize` (9500) and the order-9000 `proxy` re-assert -- an
installer's pending reboot would leave no flag and the orchestrator would never
learn. (3) Nothing clears `validation.json` (`run-verify-only.ps1` is its only
writer and is operator-run), so a pre-repair `fail` re-targeted the repaired
module on every later payload change, indefinitely.

**What:** (1) The per-module compare now runs **before** the aggregate-hash skip;
the hash decides only whether a no-drift result means "skip" or "run the full
set". (2) `module.json` gains `"always": true`, collected by the build into
`build-manifest.json`'s `always_modules`; `DriftReport.targets` folds them into
any non-empty target set in build order, and `DriftReport.drifted` still reports
what actually drifted. They never cause a run on their own. (3) `classify`
ignores a tier-2 entry whose report `checked_at` predates that module's
`installed_at` -- it describes a build no longer on the unit. An unparseable
timestamp keeps the verdict rather than silently suppressing a reported failure.

**Implications:** the aggregate hash is now a *fast-skip* input rather than a
gate, so `classify()` runs every cycle (pure logic over data already fetched).
`fleet-drift-report.py` grew a Tier-2 section: it had parsed `validated_at` and
never rendered it, which is what let the staleness stay invisible. Also removed
in the same pass: a dead `inst_hash == _UNKNOWN` comparison and the unreachable
`build_modules` fallback flagged in review. The four earlier drift flow tests
asserted no exit code and were in fact ending at `EXIT_UNIT_FAIL` on a missing
smoke marker; they now answer smoke for the build's modules and assert
`EXIT_OK`, which is what made the new regression tests meaningful.

---

## [2026-08-02] Per-module drift decides what runs; two tiers, one classifier

**Why:** The driver compared a single `payload_hash`, so any difference meant a
full cycle -- every module reinstalled because one changed. And the comparison
could not distinguish "the payload changed" from "the unit broke": a stopped
service leaves the hash matching perfectly.

**What:** `server/prov/drift.py` classifies each module as up-to-date /
needs-update / missing / extra / needs-repair from the unit's cumulative
`installed-manifest.json` vs the payload's `build-manifest.json`, keyed on the
**content hash** (the version string is reporting only, per the epic's locked
decision 2). The driver runs it after the aggregate-hash gate and passes the
drifted set to execute as `-Modules`, so a one-module drift runs one module.

**Targeting happens at execute, not at build.** Building only the drifted subset
was the obvious alternative and is wrong: the payload's `build-manifest.json`
would then declare only that subset, and the unit's `fully_provisioned` -- judged
against the build's module list -- would read true after a one-module run. The
build stays full; only execution is narrowed.

**Two tiers, one vocabulary.** Tier 1 is the written record. Tier 2 is computed:
`client/run-verify-only.ps1` (already the verify dispatcher -- extended rather
than duplicated into a new `validate-unit.ps1`) writes
`C:\MAST\status\validation.json`, and a module whose hash matches but whose
live verify fails classifies **needs-repair**. Absent tier-2 data means "not
run", never "failed", so a unit that has never run verify-only is not
manufactured into drift. `needs-update` wins over `needs-repair` when both
apply -- the remedy differs and the payload change is the larger fact.

**Content-aware verify (resolution rule 2).** `verify-desktop-shortcuts.ps1` was
presence-only, so the epic's worked example -- repointing the FastAPI shortcut --
passed it. It now takes `-FastApiUrl` injected from `module.json`'s verify
command (the same place the provider's arg comes from, so the two cannot drift)
and compares the deployed `.url` target against what this build expects. Adding
the arg also folds it into the module's content hash, which hashes resolved
commands.

**Implications:** `tools/fleet-drift-report.py` renders a per-unit x per-module
status matrix and imports the **same** `classify`, so the report cannot disagree
with what the next cycle will do; its old cross-unit modal comparison remains as
the no-`--build-manifest` fallback. `extra` (a module the unit has and the build
no longer ships) is reported but never actioned -- removing software is out of
scope for a drift pass. Tests: `server/prov/tests/test_drift.py` and the
targeted-update cases in `test_driver_flow.py`.

---

## [2026-08-02] installed-manifest.json is cumulative, per-module, and written on partial runs

**Why:** Execute copied `build-manifest.json` wholesale and stamped `installed_at`,
which made the unit's record **last-payload-only**: a `-Modules <subset>` touch-up
overwrote the document with just that subset, so the unit could no longer answer
"am I fully provisioned". The write was also gated on `failCount -eq 0`, so a run
where a single module failed wrote nothing at all and the record kept describing a
payload from days earlier -- the next cycle could not tell which modules were
actually current.

**What:** `client/mast-installed-manifest.ps1` (dot-sourced by execute, staged
beside it, unit-testable without a provisioning run) merges per-module entries
`{version, hash, provide, verify, installed_at}` for the modules a run actually
touched; untouched modules keep their prior entry. `provide` and `verify` are
tracked separately because a module can install and then fail its own verify, and
because a module with no verify command records `none` rather than a false `pass`.
Written on **every** run, partial included. `fully_provisioned` is derived: every
module the build declares is present, hash-matched, `provide = pass`, not
`verify = fail`.

**Implications:** the aggregate `payload_hash` -- the fast path
`check-and-provision.ps1` and `server/prov/driver.py` compare to decide
"already_current" -- is published **only** when `fully_provisioned`. A partial run
leaves it absent, the fast path misses, and the unit falls through to a run instead
of being skipped as current; absent must never read as a match, so the PS driver's
read was made explicit rather than relying on a silent `$null` from a missing
property. A legacy pre-`modules` manifest is read without error and simply carries
nothing forward, which is the one-time mast01-04 migration. `tools/fleet-drift-report.py`
still reads the now-absent `module_versions` from the installed manifest and is
rewritten in Stage 3 to key on `modules`. Tests:
`server/tests/mast-installed-manifest.Tests.ps1`.

---

## [2026-08-02] `repofiles`: modules may stage shared tooling from the repo top

**Why:** The `mast` module is handing its cloning to `tools/mast-clone.ps1`
(#31), a script deliberately shared with the control host and dev boxes -- the
single source of truth the adoption exists to gain. But the staging pass
resolves a `commandfiles` entry as `Join-Path $providersRoot $module $cmdfile`
and mirrors that relative path into staging, so the two obvious ways to get the
script into the payload are both wrong: copying it into
`server/providers/mast/` at build time forks the shared file, and a
`../../tools/mast-clone.ps1` entry resolves correctly on the source side but
writes **outside** the staging root on the destination side.

**What:** `module.json` gains an optional **`repofiles`** array -- paths relative
to the **repo top**, staged to the staging root **by leaf name** (the flattening
`assets/*` already gets, so the module's `command` invokes them as
`.\mast-clone.ps1`; the unit-side executor runs every command with the staging
root as its working directory, so a nested path would not be found).
Resolution and containment live in the new dot-sourceable
`build/build-staging-lib.ps1` (`Resolve-MastRepoFile`,
`Get-MastRepoFileStagingPath`, `Get-MastModuleRepoFiles`) so Pester can exercise
them without running a build, mirroring how `build-manifest-lib.ps1` was split
out. An entry that is absolute, contains a `..` segment, resolves outside the
repo top, names a directory, or does not exist is a **build error** -- a build
must not reach arbitrary paths on the build host, and a typo must break the
build rather than silently omit a file the unit-side command then cannot find.
Tests: `server/tests/build-staging-lib.Tests.ps1`.

**Implications:** Stage 3 of #31 declares
`"repofiles": ["tools/mast-clone.ps1", "tools/mast-repos.tsv"]` on the `mast`
module; no module declares the key yet, so the mechanism is inert until then.
`repofiles` are a determinant of a module's deployed output exactly as its
`commandfiles` are, so the per-module content hash must cover them -- which
cannot be wired here, because `Get-ModuleContentHash` /
`build/build-manifest-lib.ps1` live on `eli/per-module-tracking` (#22 Stage 1)
and have not reached `eli/provisioning-v3`. Tracked as an explicit follow-up in
`docs/mast-clone-adoption-plan.md` Stage 1, to be closed when the two branches
meet; until then a changed `mast-clone.ps1` is caught by the aggregate
`payload_hash`, not per-module.

---

## [2026-08-02] `mast-repos.txt` clones the upstream integration branches

**Why:** The repo list still pointed at the personal fork's dev branch --
`elibrody-weizmann/MAST_unit.2024-12-12 eli/vm-provisioning` and
`elibrody-weizmann/MAST_common eli/vm-provisioning` -- set in May 2026 while
bringing MAST_unit up on the provisioning VM. Retiring the fork (entry below)
deleted the MAST_common branch, so `provide-mast.ps1` would have failed at clone
on the next run: the module that installs MAST itself, broken by a cleanup
elsewhere. The fork branch was stale regardless (tip 2026-06-21, and its own
last commit was already repinning the submodule to `The-MAST-project` master),
and it predates the upstream requirements pinning of Jul-Aug 2026.

**What:** Both lines now name `The-MAST-project` with an explicit ref --
`MAST_unit.2024-12-12 main`, `MAST_common master`. The refs are given
explicitly, and the file says why: the two repos do not share one integration
branch, and an omitted ref silently follows whatever the remote default happens
to be at clone time. That pointer had in fact drifted -- MAST_common's default
named a dead 2024 `main` -- which is what motivated the rule; the dead branch
was deleted and the default corrected to `master` the same day
(`MAST_common#14`), so the pointer is right today and the explicit refs are
what keep a future drift from reaching the units. Integration branches were
derived from merged-PR bases and branch-tip recency, not from
`defaultBranchRef`.

**Implications:** Provisioned units now receive the pinned `requirements.txt`
from both repos, so a unit venv becomes a deterministic function of the
checked-out commit -- the precondition that makes per-module hashing meaningful
for the `mast` module (see `docs/per-module-tracking-plan.md`, Stage 1b). Both
entries are still **branch** refs, so the existing-clone path continues to
`fetch` + `reset --hard FETCH_HEAD` and the deployed content moves under a fixed
module hash; Stages 1b/2 are what close that.

---

## [2026-08-02] Retire the personal fork; a single `origin` points at the integration repo

**Why:** Every clone carried two remotes -- `origin` = `elibrody-weizmann/<repo>` and
`upstream` = `The-MAST-project/<repo>` -- a layout no fresh `git clone` produces, so the
word "origin" meant different repositories depending on which machine you typed it on. The
fork had also stopped earning its keep: work is pushed straight to branches on the
integration repo, and 12 of 13 open PRs already had their head branch there. Auditing the
forks found their remaining exclusive content was either already reapplied upstream or
obsoleted by the config-file epic.

**What:** The forks' remaining branches were deleted, then in each clone `origin` (the
fork) was removed and `upstream` renamed to `origin`. Two machines hold MAST checkouts --
this one and the Windows provisioning box -- and both were converted in the same pass, so
no window existed where "origin" was ambiguous between them. `MAST_scheduler` and
`mast-claude-config` were untouched: the former has no upstream repo (the fork *is* the
repo), the latter already pointed at The-MAST-project.

**Implications:** `git fetch` / `git push` with no remote argument now reach the
integration repo, and a fresh clone matches an existing checkout exactly. Anything written
against the old two-remote model -- scripts, notes, agent instructions saying `git fetch
upstream` -- is wrong and should be read as plain `git fetch`. Pushing a branch now
publishes it on the shared repo immediately, with no fork staging step in between, so
branch names are visible to everyone the moment they are pushed.

---

## [2026-07-29] mast-clone: dev tooling in the venv, role-named workspace, submodule disarmed

**Why:** Four things surfaced once `mast-clone` was actually run on a unit and on the
control host rather than only under `pwsh` on Linux.

The generated workspace carried a **doubled** interpreter path
(`C:\\temp\\...\\python.exe` after JSON decoding). The `.ps1` escaped backslashes with a
four-backslash replacement, but .NET replacement strings treat a backslash as literal
rather than as an escape, so each separator was doubled twice. Invisible on Linux, where
`Join-Path` produces forward slashes and there is nothing to escape.

The venv had **no ruff**. Every repo pins `ruff==0.16.0`, but in `requirements-dev.txt`,
which the scripts never installed -- and the pin is deliberate policy, not incidental:
each `ruff.toml` says outright that config alone is not enough because formatter output
differs between ruff versions.

`control` and `gui` clones showed an **empty `common` folder marked as a submodule**. The
consumers still carry a committed gitlink, so a clone without `--recurse-submodules`
leaves the mount point empty. Harmless for imports -- `<top>/common` has an `__init__.py`
and so is a regular package, which beats an empty directory (a namespace portion)
wherever it sits on `sys.path`, verified with `<top>/<repo>` deliberately first -- but a
stray `git submodule update --init` would materialise a SECOND `common`, stale from the
moment `<top>/common` moves.

Finally, `mast.code-workspace` was a fixed name, so a machine with two top folders for
different roles would have two files called the same thing.

**What:**

- `.ps1` backslash escaping fixed: the replacement is now two backslashes, which is what
  JSON needs. Verified by round-tripping the generated file through a JSON decoder rather
  than by reading the code.
- The workspace is named `mast-<role>.code-workspace`; multiple roles sort and join, so
  `--role unit,spec` yields `mast-spec-unit.code-workspace`.
- Each repo's `requirements-dev.txt` joins the same single `uv pip install`, bringing
  `ruff==0.16.0` and `pytest`. The workspace also sets `"ruff.importStrategy":
  "fromEnvironment"`, without which the Ruff extension uses its own bundled binary and
  the pin is decorative.
- After cloning, each consumer that still declares the submodule gets
  `submodule.common.update = none` in its **local** config, so `git submodule update
  --init` reports `Skipping submodule 'common'`. Note `submodule.<name>.active = false`
  is NOT sufficient: `--init` overrides it and clones anyway.

**Implications:**

- **The submodule is disarmed, not removed.** `.gitmodules` still declares it and the
  gitlink is still committed, so anyone cloning outside these scripts gets the old
  behaviour, and the empty folder still shows in VS Code. Local config was the only lever
  that leaves the working tree clean: `git rm --cached common` or removing the directory
  both leave every clone permanently dirty, which would break `--update` (fast-forward
  only, clean tree). Retiring the submodules properly remains one small PR per consumer.
- **Dev dependencies are installed on units too.** `ruff` and `pytest` are unnecessary
  there but harmless, and gating dev deps by role costs more complexity than the two
  packages are worth.
- **Dev pins now participate in the joint resolve,** so two repos sharing a machine must
  agree on their ruff version as well as their runtime pins. All repos pin `0.16.0`
  today, so this is currently a no-op.
- **Windows-only defects need a Windows run.** Both bugs fixed here, and the PowerShell
  5.1 native-stderr bug before them, were invisible to every test run under `pwsh` on
  Linux. Treat a Linux `pwsh` pass as a syntax check, not as validation.

## [2026-07-28] mast-clone: the venv is unconditional at `<top>/.venv`, installed in one resolve

**Why:** The first cut of `tools/mast-clone.{sh,ps1}` (see the entry below) made the
virtual environment optional and caller-placed: `--venv <path>` / `-Venv <path>`, with
`--no-install` and `--no-seed` to opt out of parts of it. Three problems followed. A
caller could point `--venv` at one directory while `--top` pointed at another, so the
`mast.pth` written inside the venv referenced a *different* source tree than the one just
cloned -- silently. The optionality meant "clone succeeded" and "the machine can run the
code" were separate outcomes with no obvious link between them. And installing each
repo's `requirements.txt` in its own `uv pip install` let a compound role clobber itself.

That last one was not hypothetical. The `control` role selects `control` *and* `gui`,
which share one machine and therefore one venv. Their requirements files had been pinned
from their own local venvs, built eleven months apart, and disagreed on five shared
packages (`astropy`, `httpx`, `pydantic`, `pymongo`, `rich`). Installed one after the
other, the last file simply won, and the control service would have run versions it was
never tested against, with nothing reported.

**What:** The venv is now unconditional and derived, never passed in. It is always
`<top>/.venv`, always created with `uv venv --seed` (so `pip` exists in it -- uv omits pip
otherwise, which breaks anything shelling out to it), always populated, and always given
a `mast.pth`. `--venv`, `--no-venv`, `--no-install`, `--no-seed`, `--python` and
`--bootstrap-uv` are all gone, along with their PowerShell equivalents. Deriving the path
from `--top` makes the mismatched-`mast.pth` case unrepresentable rather than merely
discouraged.

Requirements are installed in **one** `uv pip install` invocation carrying every selected
repo's `-r`, rather than one call per repo. uv then resolves them together and fails
loudly on a contradiction. Reconciling the pins is the caller's job, and the failure text
says so.

`uv` is acquired rather than requested: since the venv is always built, a missing `uv`
would only ever mean a broken run, so the pinned `#!uv-version` is fetched into
`<top>/.tools` automatically when uv is absent -- still checksum-verified against the
`.sha256` GitHub publishes, still never `curl | sh`, still never "latest". The
interpreter *version* remains deliberately unpinned: which Python a machine has is
provisioning's concern, not this script's.

Both scripts also generate `<top>/mast.code-workspace`, a VS Code multi-root workspace
listing the folders actually cloned. Opening `<top>` as a plain folder would make VS Code
read only `<top>/.vscode` and ignore the per-repo `.vscode` directories that `control`,
`spec`, `gui` and `unit` each ship (all tracked); a multi-root workspace is the one
arrangement where each repo keeps its own folder-scoped `settings.json` and its
`launch.json` entries, with nothing copied or merged. It is written only when absent, so
a hand-edited workspace survives `--update`.

**Implications:**

- **There is no clone-only mode any more.** Every run builds and populates the venv, so
  every run needs network and takes install time. `--update` refreshes the checkouts
  *and* re-resolves. That is the price of "a successful run means a runnable machine".
- **Repos that share a machine must agree on shared pins.** This is now enforced rather
  than hoped for. `MAST_control` and `MAST_gui` were re-pinned jointly against PyPI to
  satisfy it; any future pair sharing a role inherits the same constraint.
- **The generated workspace sets `python.analysis.extraPaths` to `[".."]`,** which is what
  makes Pylance resolve `common` from each folder -- `mast.pth` fixes runtime, but static
  analysis does not reliably follow `.pth` files. A folder-scoped `extraPaths` *replaces*
  the workspace value rather than merging with it, so `MAST_unit` -- the only consumer
  that sets `extraPaths` itself, for the Standa ximc wrapper -- had to prepend `".."` to
  its own list. Any repo that later adds `extraPaths` must do the same.
- **`python.defaultInterpreterPath` in the generated workspace is an absolute path.**
  `<top>/.venv` is a sibling of the folder roots rather than inside one, so VS Code cannot
  auto-discover it. The file is generated per machine, so a machine-specific path in it is
  acceptable; it is not something to commit anywhere.
- Extension entries in the workspace are **recommendations only** -- VS Code prompts, it
  never installs. Installing them (`code --install-extension`) is provisioning's job; a
  unit may have no editor at all.

## [2026-07-28] Role-driven flat source layout: `mast-clone.{sh,ps1}` + a single `common` clone

**Why:** `MAST_common` was vendored into four consumers as a git submodule (`common/` in
control, gui, spec; `src/common/` in unit). That costs a `chore/bump-common-gitlink` PR in
every consumer for each common change -- three of the four had one as their most recent
commit -- and it means four working copies of the same code on a dev box. Separately, there
was no single command to lay down "the repos this machine needs", either at provisioning
time or when cloning a dev environment.

**What:** `tools/mast-clone.sh` and `tools/mast-clone.ps1` populate a top folder with a flat
hierarchy whose folder names are fixed: `common`, `unit`, `control`, `gui`, `spec`, `claude`.
A `-Role` / `--role` parameter (`unit`, `control`, `spec`, `all`) selects the subset; roles
union and de-duplicate, so `all` needs no special case. `gui` is deliberately *not* a role --
it ships as part of `control`. `claude` (mast-claude-config) comes with every role.

Both scripts read one manifest, `tools/mast-repos.tsv` (dir / repo / roles / branch); neither
hardcodes a repo list, per the repo's DRY rule. Adding a repo is a one-line manifest change.

The `common` folder name is load-bearing rather than cosmetic. `MAST_common`'s repo root
carries an `__init__.py`, so the repo root *is* the `common` package. Cloning it into a folder
named exactly `common` and putting `<top>` on `sys.path` makes all ~982 existing
`from common.X import ...` statements resolve unchanged -- no source edits, no submodule.
Cloning it as `MAST_common` (the old habit) cannot work, which is precisely why each vendored
copy carries a `common/tests/conftest.py` that fabricates a module alias via
`importlib.util.spec_from_file_location`; that shim and the five ad-hoc `sys.path.insert`
sites in MAST_gui become deletable.

`sys.path` is wired with a `mast.pth` written into a venv's `site-packages` (`--venv` /
`-Venv`), not by exporting `PYTHONPATH`. The MAST code runs as NSSM services on units and
systemd on Linux hosts, neither of which inherits a shell environment; a `.pth` is per-venv
and additionally works for pytest and IDE test runners. `PYTHONPATH` remains a documented
convenience for interactive shells only.

`--venv` / `-Venv` does not merely write that `.pth`: it creates the venv and installs each
cloned repo's `requirements.txt` into it, so one command takes a bare machine to a runnable
one. Provisioning no longer owns venv population. **One venv per machine**, not per repo --
the `.pth` puts every cloned repo on `sys.path` at once, so a second venv would isolate
nothing; on the control host that means the control and gui services share it.

`uv` does both jobs (`uv venv`, `uv pip install`) and is **required**, not preferred. A
fallback to `python -m venv` + `pip` would resolve a different dependency set than uv locks
onto, so a fleet provisioned by two different paths would drift -- the exact failure this
layout exists to prevent. `--bootstrap-uv` / `-BootstrapUv` fetches the version pinned by the
`#!uv-version` directive in the manifest, verifies it against the `.sha256` GitHub publishes
beside the release artifact, and unpacks the single static binary into `<top>/.tools`. It is
deliberately not `curl ... | sh` / `irm ... | iex`: a pipe executes whatever the URL serves at
that moment, unreviewed, and installs "latest", which reintroduces per-machine drift. The venv
is seeded (`uv venv --seed`) so `pip` exists in it, since uv otherwise omits it and anything
shelling out to `pip` breaks; `--no-seed` opts out.

**Implications:**

- **Branches are pinned in the manifest, never taken from the remote's default HEAD.**
  `MAST_common`'s GitHub default branch is `main` with 2 commits (last 2024-12-28) while all
  721 commits of real work are on `master`; `MAST_control` has the same trap (`main`, 2
  commits, 2024-04-26, vs 148 on `master`). A plain `git clone` lands on the stub and yields a
  `common/` with no `__init__.py`, breaking every import on the unit. The consumers'
  `.gitmodules` already pinned `branch = master`, corroborating this. Both scripts therefore
  hard-fail if `common/__init__.py` is absent after cloning. Fixing the two GitHub default
  branches would remove the trap; until then the manifest column is the only guard.
- **Sibling folders become importable top-level names,** and three collide with real modules:
  `spec/spec.py`, `unit/src/unit.py`, `control/control/`. This resolves correctly *only*
  because those repo roots have no `__init__.py` -- a directory without one is merely a
  namespace portion, and a real module found anywhere on `sys.path` beats it regardless of
  path order (verified against the real repo trees with `<top>` deliberately first). Adding an
  `__init__.py` to any consumer repo root would silently shadow that repo's own module, so
  both scripts warn when they see one.
- **The scripts are safe to adopt before de-submoduling.** A clone without
  `--recurse-submodules` leaves `<repo>/common/` empty; an empty directory loses to
  `<top>/common/__init__.py` under the same namespace rule. Removing the submodules from the
  four consumers is therefore an independent follow-up, not a flag day.
- Re-running is idempotent: existing clones are fetched, never merged, unless `--update` is
  given, and even then only fast-forward and only on a clean tree.
- **`GIT_TERMINAL_PROMPT=0` is set in both scripts.** Provisioning is unattended, so git must
  never stop to ask for credentials. Without it, a private repo (`MAST_unit.2024-12-12` is the
  only one) sends git through Git Credential Manager, which cannot persist to `wincredman` in
  a non-interactive session, then tries to open a tty, and only then reports a confusing
  "could not read Username". With it set, the clone simply succeeds where a usable credential
  exists and fails immediately and legibly where it does not.
- **Windows PowerShell 5.1 turns a successful `git clone` into a fatal error.** With
  `$ErrorActionPreference = 'Stop'`, 5.1 wraps every stderr line of a native command
  redirected via `2>&1` into an ErrorRecord and throws on the first one -- and git writes
  ordinary progress ("Cloning into '...'") to stderr. PowerShell 7 does not, so this is
  invisible to any test run under `pwsh` and only bites on the 5.1 target, which is where
  provisioning runs. `Invoke-Native` drops the preference to `Continue` for the duration of
  each native call and reports success from `$LASTEXITCODE` instead. Any future native
  invocation in this script must go through it.
- This is the first `.sh` in a repo that was until now 100% PowerShell. The bash half exists
  because the control and gui hosts are Linux; the two scripts must be kept in step, with
  `mast-repos.tsv` as the shared source of truth.

---

## [2026-07-23] build-manifest.json carries per-module content hashes (`module_state`)

**Why:** Drift detection is whole-payload: the single `payload_hash` over the
flattened staging tree can say a unit differs from the build but not *which
module*, so any drift means a full reprovision. The per-module-tracking epic
(#22) needs a per-module fingerprint on the build side first (Stage 1). The
hash boundary must cover more than file bytes: a module's deployed output is
also shaped by build-time injected command args (`-Site`, `-ForceMode`,
`-RpiNtp`, the desktop-shortcut `-FastApiUrl` -- which lives only in
`module.json` `command`), which no staged-file hash sees. The worked example
that must register as drift: repointing the FastAPI shortcut URL changes no
commandfile byte at all.

**What:** `build-manifest.json` gains `module_state`: per module `{version,
hash}`. `Get-ModuleContentHash` (in the new dot-sourceable
`build/build-manifest-lib.ps1`, where `Get-PayloadHash` also moved so Pester
can test both without running a build) hashes (a) the module's source
commandfiles under `server/providers/<module>/` -- hashed at the source, since
staging is flattened and has no per-module subtree; (b) the module's
**resolved** `commands.json` entries (provide + verify + any finalize), i.e.
the command strings with the injected args baked in; (c) the resolved version
(`git` -> SHA, as in `module_versions`). File lines sorted by path, command
lines order-preserving (execution order is behavior), category prefixes
(`file:`/`cmd:`/`version:`) keep inputs collision-free. Missing commandfiles
are skipped -- by hash time a gap can only be a `-TestMode` optional payload;
production builds have already thrown in the staging pass. `module_versions`
stays alongside as a deprecated duplicate (`tools/fleet-drift-report.py` still
reads it; removed when the report keys on `module_state` in Stage 3). The
aggregate `payload_hash` is unchanged as the fast "anything changed?" gate.
Tests: `server/tests/build-manifest-lib.Tests.ps1`.

**Implications:** Stage 2 can merge `{version, hash}` per executed module into
a cumulative `installed-manifest.json`; Stage 3 gets per-module drift
classification and targeted `-Modules` updates. Build-host-vendored payloads
(cygwin-pkg-cache, mast-indexes, NetFx3 SxS, licenses) are *outside* the
per-module hash boundary -- the aggregate `payload_hash` still catches their
staged bytes; the same accepted boundary is documented in #24 for the release
version. Plan: `docs/per-module-tracking-plan.md`.

## [2026-07-23] Astrometry cygwin installs offline from a frozen package cache

**Why:** `provide-astrometry-dependencies.ps1` installed cygwin from the
**live** itefix mirror (`--site https://cygwin.itefix.net --upgrade-also`),
while the bundled fitsio wheel is **version-pinned** in its filename tag
(`cygwin_3_6_9`). pip derives the cygwin platform tag from the *running*
cygwin, so when the rolling mirror moved 3.6.9 -> 3.6.10 a fresh provision
installed 3.6.10 and pip rejected the wheel ("not a supported wheel on this
platform"), failing the module on any newly provisioned unit (issue #20).
Root cause: a pinned wheel coupled to an unpinned, live-mirror-tracking
cygwin.

**What:** Freeze the exact known-good package set and install fully offline.
The cache is **harvested once from a working unit** (mast01's own
`C:\cygwin64\var\cache\setup`, ~174 MB -- authoritative because it *is* what
the validated fleet installed) via the new `build/harvest-cygwin-cache.ps1`,
stored **build-host-vendored** at `C:\MAST\cygwin-pkg-cache` (like the
astrometry index seed -- binary, not in git), staged into the payload by
`build-mast.ps1` (warn under `-TestMode`, throw for production builds), and
installed with `setup-x86_64.exe --local-install --upgrade-also` (no `--site`
download; `--upgrade-also` is kept -- the cygwin provider's tgz ships an older
base (3.6.5) and without the flag setup leaves it in place, so pip's platform
tag stays `cygwin_3_6_5` and the pinned wheel is still rejected; against the
frozen ini the flag is deterministic and reproduces the fleet's actual
2026-07-06 transaction). Version stays **3.6.9** rather than re-pinning to 3.6.10:
it matches the existing wheel (no rebuild), keeps the fleet uniform
(mast01-04 already run 3.6.9), and a patch bump buys nothing used here
(identical `cygcfitsio-10` / `libpython3.9` ABI) while costing a wheel
rebuild + fleet re-provision. The proxy plumbing the online download needed
(`-ProxyMode`, `setup.rc` net-method, `--proxy`, the WinINet
cert-revocation toggle) is removed from this provider -- it was
download-only. Module version bumped to `0.97-deps-2`.

**Implications:** The installed cygwin is deterministic regardless of what
the live mirror serves, and astrometry-deps now works on offline/bench units
(an #8 gap). **Locked coupling:** the frozen cygwin version and the fitsio
wheel tag move together -- refreshing the cache to a newer cygwin REQUIRES
rebuilding the wheel in the same change (documented in DEPENDENCIES.md).
Real units need no re-provision (already 3.6.9); each build host needs the
one-time harvest. Full plan: `docs/cygwin-freeze-plan.md`.

## [2026-07-19] Transfer phase fails CLOSED: whitelist `OK`, not blacklist two failures

**Why:** A code review before switching the autonomous loop on found the SMB
transfer phase was the only phase that failed *open*. `prov.driver._transfer`
rejected exactly two pull outcomes (`NET_USE_FAIL`, `ROBOCOPY_ERROR`) and let
everything else fall through to `TRANSFER_OK` -- so `NET_USE_HUNG`,
`DISK_INSUFFICIENT`, and (worst) a **missing/garbled `PULLRESULT` marker** were
all treated as successful transfers, and the driver would proceed to *execute*
against a staging dir that was never verified as copied. The remote rc from the
pull is not even checked. Every other phase already fails closed (smoke treats a
missing marker as `<missing>`->FAIL; execute requires `DETACHED_REGISTERED` + a
`status=="done"` poll). This is the one gap that matters for unattended runs. The
PowerShell driver (`server/check-and-provision.ps1`) has the identical logic --
the Python port faithfully reproduced it.

**What:** `_transfer` now **whitelists the single documented success outcome**:
`TRANSFER_OK` requires `outcome == "OK"` (the pull script's own success value;
robocopy rc 0-7). Any other outcome -- or an unparseable/absent marker -- logs
`TRANSFER_FAIL` (with a specific `reason`: `net_use_failed`, `net_use_hung`,
`robocopy_error`, `disk_insufficient`, or `unrecognized_pull_result`) and stops
the unit before execute. This is a **deliberate divergence from PowerShell
parity**: the Python driver is the go-forward orchestrator (the PS driver is
slated for retirement), so it is corrected rather than kept bug-compatible.

Landed alongside two transport-hygiene fixes and a test-harness addition, all in
the same review pass:
- `prov.transport` no longer `sys.exit()`s at import when pywinrm is missing --
  it raises a catchable `ImportError`. `sys.exit` on import killed any tool/test
  that merely imported the module and broke the module's stated import-purity.
- `dump_json_file` writes `newline="\n"` so a Windows prov server cannot emit
  CRLF, matching the UTF-8-no-BOM + LF standard already used by
  `write_status_atomic`.
- New `server/prov/tests/test_driver_flow.py`: an in-process `FakeSession`
  (subclassing `SshSession`, no paramiko) drives `Driver._process_unit` through
  the full phase flow, covering the happy path and the transfer / execute / smoke
  / register / reachability failure branches -- the orchestration layer the
  earlier suite left entirely to the VM run. Suite: 74 passed, `ruff check` clean.

**Implications:** A transfer that used to be silently accepted (hung mount, full
disk, lost marker) now fails the unit loudly and is retried next cycle instead of
executing against a bad payload. A future pull-script change that adds a new
success outcome must also be added to the whitelist (fail-closed by default is
the intended safety posture). Log/telemetry change: two `TRANSFER_FAIL` activity
reasons were unified into the `{reason}_rc_{rc}` form. The VM re-validation
(negative test: break the pull, confirm it fails closed and does not execute) is
the acceptance gate before this ships. `ruff format` is intentionally NOT run --
this repo lints with `ruff check` only and is not format-managed.

---

## [2026-07-12] Activate the autonomous loop: `--loop` service mode

**Why:** Item 8 -- the last gate for the autonomous provisioning goal. The driver
needs to run continuously on a cadence (the requirements doc's "long-lived service
beats periodic-fire scheduler"), replacing the PowerShell `install-scheduled-task.ps1`
+ Task Scheduler path with a platform-agnostic Python service.

**What:** `server/check_and_provision.py --loop` runs `Driver().run()` cycles on
`--interval-seconds` (default 1800), via `prov.driver.run_loop`. A fresh Driver per
cycle (fresh run_id / log dir); per-unit maintenance windows already gate the
disruptive steps, so the loop just fires on cadence and each unit provisions only
inside its window. A cycle that throws is logged and does NOT stop the loop (a
service must stay up). SIGINT/SIGTERM set a stop event used both as the between-cycle
check and the interruptible inter-cycle sleep (`ev.wait`), so a stop signal exits
promptly instead of waiting out the interval. `--max-cycles N` bounds a run
(supervised one-shot / testing). The per-OS **service wrapper** is the only part
that differs by platform -- example `server/deploy/mast-provision.service` (systemd)
and NSSM instructions in `server/deploy/README.md`; the loop itself is portable.

**Implications:** Validated on the mast-unit VM (two dry-run cycles ~interval apart,
each a fresh run to `exit_code=0`, then clean stop at `--max-cycles`). With items 1-8
landed, the Python driver covers the full autonomous path; flipping it on is a
deployment step (install the service, set `--interval-seconds` + `MAST_SERVER_ROOT`).
The PowerShell driver + `install-scheduled-task.ps1` stay until retired. Real-fleet
cadence + reboot-survival still await a real unit (VM reboots don't return reachable
-- harness artifact, see the reference memory).

---

## [2026-07-12] Detached execute: run provisioning as a self-detaching task the driver polls

**Why:** The synchronous execute (run over the WinRM/SSH session, driver blocks on it)
dies if the transport session drops mid-run -- the "execute dies with its session" failure
that #6/#7 call out, and the one advantage WinRM had (resume a Receive across a blip). For
the unattended loop, execute must survive a session drop; that also unblocks WinRM retirement.

**What:** Execute now runs **detached** from the driver's session, encapsulated in one
standalone unit-side script `client/mast-run-detached.ps1` (Eli's "put the moving parts in a
script that runs standalone on the unit" steer):
- `-Register`: registers a **triggerless** scheduled task (interactive `mast`, elevated) that
  re-invokes the script `-Run`, then Starts it and returns. Triggerless = it only runs when
  Started, so it never re-fires at a later logon and re-provisions the unit.
- `-Run` (in the interactive session): reads `detached-run.json`, decrypts the SMB password
  from the DPAPI-`LocalMachine` blob, runs `execute-mast-provisioning.ps1`, and writes
  `execute-result.json` (`running` -> `done` + `exit_code`).
- The driver writes the inputs (config + blob), invokes `-Register`, then **polls
  `execute-result.json`**, reconnecting (`connect_unit`) if the session drops, bounded by the
  `EXECUTE_TIMEOUT_S` watchdog; it reads `exit_code` and deletes the task. Returns the
  (possibly reconnected) session so downstream phases use the live one.

**Credential handling:** execute needs the SMB password (it maps `Z: -> \\prov\mast-shared`).
A network-logon session (SSH/WinRM) **cannot** `cmdkey` (validated: "Credentials cannot be
saved from this logon session"), so the driver writes the pass as a **DPAPI-`LocalMachine`**
blob (machine-bound, encrypted, never plaintext; a network logon CAN LocalMachine-Protect) and
the detached runner decrypts it in the interactive session (LocalMachine decrypts from any
session on the box). No credential is passed to the detached process and none sits in
cleartext. See the reference memory / `reference_mast_unit_windows_cred_reboot`.

**Implications:** Validated end-to-end on the mast-unit VM (detached task ran execute, Z:
mapped from the decrypted blob, driver polled the marker to `exit_code=0`, smoke passed).
The **session-drop reconnect** and **reboot-survival** (`-AllowReboot`) paths are coded but
not VM-validatable here -- in-place VM reboots don't return reachable (a VBox harness artifact,
see the reference memory), so those await a real unit. WinRM retirement can follow now that the
detached task, not a live Receive, carries execute across drops. The steady-state durable-Z
provider (`mast-shared-mount`, so Z: persists across reboots without provisioning) is a
separate later item; detached execute maps Z: itself via the decrypted blob.

---

## [2026-07-12] Adopt SSH-first transport and a UTF-8-no-BOM JSON standard

**Supersedes** the "directional (recommended, not yet committed)" note at the end
of the same-day "Port the provisioning server orchestration to Python" entry
below -- Eli approved both, so they are now decided.

**Why:** As the server orchestration becomes platform-agnostic Python, the two
Windows-flavored fragilities in the transport/data layer should go. WinRM
Basic-over-HTTP carries a large resilient-Receive retry layer (it exists only
because WinRM's HTTP Receive model breaks under load), ships credentials base64
on 5985, imposes the EncodedCommand size ceiling, and is the channel that fails
the post-reboot Public-profile 401 -- exactly where SSH already saves us. And PS
5.1's UTF-8 BOM on written JSON trips every non-PowerShell reader.

**What:**
- **SSH-first transport.** `prov.transport.connect_unit` now prefers SSH (paramiko),
  with WinRM (pywinrm) as fallback (`prefer='ssh'` default). WinRM stays as the
  fallback until item 6's detached-execute lands -- which neutralizes WinRM's only
  real advantage (resuming a command across a network blip) -- after which the WinRM
  code retires. Recommendation + rationale recorded on #6; robustness pairing is #7.
- **UTF-8-no-BOM + LF for all MAST JSON.** The Python driver writes plain UTF-8 +
  LF and renames atomically (`os.replace`); reads stay BOM-tolerant
  (`transport.load_json_file` / `parse_json_text`) as a permanent safety net for
  existing PS-written files. Follow-up: unit-side PS writers (execute, availability)
  switch from `Out-File -Encoding UTF8` to `[IO.File]::WriteAllText` with a no-BOM
  `UTF8Encoding($false)` (5.1 has no `utf8NoBOM`).

**Implications:** OpenSSH goes from fallback to load-bearing on every unit
(bootstrap-winrm.ps1 already installs it); host keys should be pinned for production
(currently `AutoAddPolicy`). The driver's own writes are BOM-free immediately; full
BOM retirement waits on the unit-side writer change.

---

## [2026-07-12] Port the provisioning server orchestration to Python (platform-agnostic)

**Why:** The autonomous provisioning loop must be platform-agnostic -- the prov
server may run on Linux -- while the provisioned units stay Windows. The driver
was PowerShell (`server/check-and-provision.ps1`), which ties the control plane
to Windows. **Standing forward requirement (per Eli):** the provisioning server
must be genuinely platform-agnostic -- all paths and mechanisms run end-to-end
against the Windows units with no per-platform patching or extra code.

**What:** A new Python package `server/prov/` becomes the server-side control
plane, replacing the PowerShell driver. Landed so far (this commit):
- **`transport.py`** -- the WinRM/SSH transport, **lifted** out of `vm/vm_lib.py`
  (which was labeled throwaway test scaffolding) so the shipped driver owns it.
  `vm_lib.py` is now a thin shim that re-exports `prov.transport` and keeps only
  the VirtualBox (test-only) helpers; the `vm/` harness is unchanged.
- **Pure-logic modules** ported 1:1 from the PowerShell libs, each with pytest
  mirroring the Pester tests: `retention.py`, `proxy_assert.py`, `winrm_flap.py`,
  `staging_size.py`, and `maintenance_window.py`. The maintenance-window port
  drops the IANA->Windows timezone shim (`mast-timezone.ps1`): Python's `zoneinfo`
  resolves IANA ids natively.
- Still to land: `logevents.py` (server-side of `mast-log.ps1`), `driver.py` (the
  orchestrator), and the `check_and_provision.py` CLI. The PowerShell driver stays
  in place and remains authoritative until the Python driver is validated on a
  real run (the deferred VM test); then it retires.

**Scope boundary (what stays PowerShell / infra):** the steps the driver *drives*
stay as-is and are invoked, not rewritten -- `build-mast.ps1` (produces Windows
staging; shelled via `pwsh`/`powershell.exe`), `mast-pull-staging.ps1` and
`execute-mast-provisioning.ps1` (run on the unit), all providers. **Transfer is
SMB for all platforms** (unit pulls via `net use`+robocopy from `\\server\share`;
a Linux server serves the share via Samba) -- one universal transfer path, share
hosting is deployment infra, not driver code.

**Implications / port gotchas being designed for:**
- **Server-side root:** the driver's own logs/status were under `SystemDrive\MAST`
  (Windows-only); the Python driver resolves a portable server root (unit-side
  `C:\MAST` is unchanged -- units are Windows).
- **Remote Windows paths are literal strings, never `pathlib.Path`** (Path mangles
  `C:\...`/UNC on a Linux server).
- **`zoneinfo` needs the `tzdata` pip package on Windows** (no bundled db there),
  else IANA ids fall back to server-local with a MAINT_TZ_WARN -- a dependency to
  add on the Windows host to preserve the timezone fix.
- **UTF-8 BOM:** reads stay BOM-tolerant (PS 5.1 writes a BOM); the Python driver
  writes plain UTF-8 + LF and uses atomic `os.replace`.
- **PowerShell exe** resolved portably (`pwsh` on Linux, `powershell.exe` on
  Windows); structured results from unit-side scripts come back as JSON over the
  session (not live PS objects); `-AllowReboot` can drop the session mid-run.

**Directional (recommended, not yet committed):** move to **SSH-first transport**
(retire WinRM, sequenced with item 6's detached-execute, which neutralizes WinRM's
only real advantage) and standardize all MAST JSON on **UTF-8-no-BOM + LF** with
unit-side PS writers switching to `[IO.File]::WriteAllText`. Recorded as direction;
decisions pending.

---

## [2026-07-12] Systematic per-run log archival + retention on the prov server

**Why:** Every run scattered evidence with no lifecycle: the controller log already landed under
`C:\MAST\logs\prov\sessions\<run-id>\`, but the unit's *own* session dir (acquisition, per-provider,
execute logs) piled up on the unit under a timestamp name and was never pulled back, `last-run.json`
held only the latest cycle, and nothing ever pruned old dirs -- unbounded growth on a host meant to
run for weeks-to-years unattended. A post-mortem depended on nothing having overwritten the evidence.
This is item 5 of `MAST_provisioning#10` -- the log *lifecycle*, distinct from item 4 (log *noise*).

**What:** The run driver now owns each run's full log set under one per-`run_id` location:
- **Deterministic unit session dir.** `client/execute-mast-provisioning.ps1` keys its session dir on
  the server-supplied `-RunId` (`C:\MAST\logs\sessions\<run-id>`) when present, instead of a local
  timestamp -- so the controller knows the exact path to pull. Manual runs (no `-RunId`) keep the
  timestamp-named dir; an explicit `MAST_LOG_SESSION_DIR` still wins.
- **Pull the unit logs back.** In the per-unit `finally` (while the PSSession is still open) the
  driver `Copy-Item -FromSession`s the unit's session dir into `<run-log-dir>\unit-<hostname>\`.
  Every non-dead session hits this -- success, smoke-fail, proxy-fail -- i.e. exactly when the
  unit-side logs matter. A dead session (network drop) cannot be pulled; that evidence stays on the
  unit (same limitation as lease release).
- **Per-run status snapshot.** `last-run.json` is also written into the run's own dir, so this run's
  outcome stays pinned next to its logs after the live file is overwritten next cycle.
- **Bounded retention.** New `-RetainRuns` (default 60) keeps the newest N run dirs and prunes the
  rest at end of run. The delete DECISION is a pure function (`Select-MastProvPrunableRuns` in
  `server/lib/mast-log-archive.ps1`, keep-newest-N by the run id's embedded timestamp); the
  filesystem runner (`Invoke-MastProvRetention`) is a thin wrapper. Non-conforming dir names are
  never pruned, and the current run is always the newest so it is never eligible.

**Implications:** A count cap (not an age cap) was chosen as the single retention knob -- it is the
one that actually bounds growth and is obviously correct; an age dimension can be added later without
changing the guarantee. Pulling the unit dir over WinRM is cheap (text logs, not FITS). The pure
retention logic is covered by `server/tests/mast-log-archive.Tests.ps1`; the pull-back and prune I/O
carry real-run acceptance on the VM/unit.

---

## [2026-07-09] Provisioning-log noise: rate-limit link-flap warnings; escalate the heartbeat

**Why:** The mast04 overnight failure (2026-07-07) buried five meaningful events under hundreds
of untimestamped WinRM "connection interrupted/restored" WARNING lines, plus an ascom step that
logged an identical "still running" heartbeat every 30 s for 65 minutes. The signal (module
boundaries, EXCEPTION, RUN_END) was un-findable without grep gymnastics. (The related
TRANSFER_PROGRESS pct>100 / negative-ETA bug is a separate commit -- the junction-aware
bytes_total fix.)

**What:** Two logging changes, keeping the meaningful signal:
- **Link-flap warnings are captured and rate-limited, not suppressed** (chosen over silencing them
  outright, per Eli). The driver captures the PSRP robust-connection warnings for each long phase
  (execute via `-WarningVariable`, transfer via the job's Warning stream) and emits ONE timestamped
  `WINRM_LINK_FLAP` summary event with interrupted/restored/other counts, via the pure classifier
  `server/lib/mast-winrm-warn.ps1` (`Measure-WinRmFlap`). A flaky link is still visible (the counts),
  but as one line per phase, not hundreds.
- **The `vm_lib.py` heartbeat escalates instead of repeating.** The timeout is still checked every
  `HEARTBEAT_INTERVAL_S` (30 s), but the LOG cadence backs off (30 s -> up to `HEARTBEAT_MAX_GAP_S`
  120 s) and, past `HEARTBEAT_ESCALATE_S` (10 min), switches to a `[WARN]` line on a slower
  `HEARTBEAT_ESCALATE_GAP_S` (5 min) cadence -- so a genuinely stuck step stands out rather than
  scrolling identically.

**Implications:** Capturing native PSRP transport warnings via `-WarningVariable` / the job Warning
stream is best-effort -- if a future PowerShell writes them through a channel these do not catch,
the `WINRM_LINK_FLAP` counts would read low; that surfaces only on a genuinely flaky link (not
reproducible on the stable bench VM), so it carries real-run acceptance. Hard phase timeouts remain
item 6 (#7); this is purely the log-noise item 4 of `MAST_provisioning#10`. Pure classifiers are
covered by `server/tests/mast-winrm-warn.Tests.ps1` and the heartbeat by
`vm/tests/test_vm_lib.py::test_run_with_heartbeat_escalates_and_rate_limits`.

---

## [2026-07-09] Operator "MAST Proxy" desktop tool + shared proxy-lib.ps1 (one implementation)

**Why:** Units must end provisioning on the Weizmann proxy, but the state is fragile (three
surfaces -- machine env, WinINet, WinHTTP) and an on-site operator arriving with a bench-provisioned
(`-ProxyMode direct`) unit needs to flip it to Weizmann and confirm it took, with no controller /
WinRM / staging. Re-implementing the surface logic in a second script would drift from the
`proxy` provider.

**What:** Factored all proxy-surface logic out of `provide-proxy.ps1` into
`server/providers/proxy/proxy-lib.ps1` (verbatim function bodies + a `Set-MastProxyState` /
`Get-MastProxyPosture` orchestration and a pluggable logger). The provider now dot-sources the lib
and routes its output into the provisioning log; behavior is unchanged (its verification readback
still guards the set). A new `set-proxy.ps1` -- an interactive Show / Set Weizmann / Set Direct /
Re-verify tool that self-elevates and probes bcproxy:8080 vs github:443 -- consumes the SAME lib.
`provide-proxy.ps1` copies both scripts to `C:\ProgramData\MAST\proxy\` and the `desktop-shortcuts`
provider adds a "MAST Proxy" shortcut under Desktop\MAST\Operations, mirroring the
`instrument-profiles` -> `calibrate-instruments.ps1` launcher pattern. Pure helpers covered by
`server/tests/proxy-lib.Tests.ps1`.

**Implications:** One proxy implementation shared by the provider and the operator tool -- no
drifting second copy. `proxy-lib.ps1` lives in the provider directory (not `server/lib`) because it
must travel to the unit alongside `set-proxy.ps1`. This is the operator proxy-tool item from
`MAST_provisioning#8`, folded into the v3 batch; it complements (does not replace) the direct-run
proxy-posture guard added the same day, whose weizmann-run warning is the "assert Weizmann" pairing
that item mentioned.

---

## [2026-07-09] End-of-run proxy-posture guard instead of patching a phantom re-introduction

**Why:** #10 item 3 ("only the proxy provider may own proxy state; audit astrometry-dependencies /
chrome / vscode") was filed against a mast03 symptom (2026-07-08): a `-ProxyMode direct` run ended
with bcproxy still set, so `git fetch` in the mast module died with "Could not resolve proxy:
bcproxy". A full code audit does not support the filed root cause: no module outside the `proxy`
provider writes any proxy surface (machine `http_proxy`/`https_proxy` env, WinINet
`ProxyEnable`/`ProxyServer`, machine WinHTTP, or the WPAD/`DefaultConnectionSettings` blob). chrome
and vscode only reference bcproxy in comments (both use offline installers); astrometry-dependencies
uses bcproxy solely to drive the cygwin `setup.exe` (`setup.rc` + `--proxy`), already keys off an
explicit `-ProxyMode` (no probing), and writes `net-method=Direct` with no proxy on a direct run.
The re-introduction was also intermittent (a later mast03 run was clean), and mast03 is unreachable
until the site trip, so the exact mechanism cannot be diagnosed now. Patching the named modules
would fix a phantom.

**What:** Rather than change proxy *management* (which stays solely in the `proxy` provider), add a
READ-ONLY end-of-run assertion. After the last module, `check-and-provision.ps1` reads the unit's
proxy surfaces over WinRM and classifies them via `server/lib/mast-proxy-assert.ps1`
(`Get-ProxyDirtySurfaces`): the machine `http_proxy`/`https_proxy` env vars are **critical** (git
reads those -- a dirty one on a `-ProxyMode direct` run is a hard `UNIT_FAIL reason=proxy_dirty_on_direct`
naming the surface); WinINet / WinHTTP are **advisory** (real proxy surfaces that do not break git,
logged `PROXY_ASSERT_WARN`). A `weizmann` run warns if the unit ended with no proxy at all (units
should end on the Weizmann proxy). Pester coverage in `server/tests/mast-proxy-assert.Tests.ps1`.

**Implications:** The guard turns exactly the intermittent, silent re-introduction that bit mast03
into a loud, surface-naming failure that will be caught on the next direct run at the site -- without
guessing at a culprit the code does not contain. It runs after `mast` (order 2200), so it catches a
proxy set by any source. The `astrometry-dependencies` hardcoded bcproxy host duplicates the proxy
provider's value; DRY-ing that (a shared `proxy-lib.ps1`) is left to the separate operator
proxy-tool item in #8, not folded in here. This is the proxy item of `MAST_provisioning#10`.

---

## [2026-07-09] Availability lease is released on every exit and reclaimable by a new run

**Why:** `check-and-provision.ps1` marks a unit unavailable (availability.json,
`available:false` + `lease_owner=<run-id>` + a 2 h `expected_return_utc`) before
provisioning, but only wrote `available:true` again on the happy-path end. Any early exit
-- a smoke-failure `continue`, a caught EXCEPTION, or a mid-run bail -- skipped that write,
leaving a live lease. The start-of-cycle check then honored the live lease of that prior run
(owner != the new run-id, not yet TTL-stale) and SKIPped, so an immediate re-run no-op'd
until the 2 h TTL. Seen on mast03 2026-07-08: the 08:19 run's lease blocked an 08:36 re-run
until the sidecar was hand-deleted. availability.json conflates two consumers -- the science
scheduler ("do not observe with me") and the driver ("do not re-provision me") -- and only
the second was buggy.

**What:** Two changes, keyed on the fact that the unit-side `execute-lease.json` is the real
mutual-exclusion guard and check-and-provision is the sole writer of availability.json.
(1) **Reclaim:** the start-of-cycle availability check now reclaims a lease held by any run
other than the current one (`AVAIL_LEASE_RECLAIM`, then re-provision), instead of SKIPping on
a live non-current lease -- an overlapping cycle would still SKIP at the execute-lease, so
this cannot cause a double-execute. This subsumes the former `AVAIL_LEASE_LIVE` (SKIP) and
`AVAIL_STALE_RECOVER` events (the TTL-expiry signal survives as a `stale=` field on the
reclaim event). (2) **Release:** a per-unit `$leaseHeld` flag drives the per-unit `finally`
to release the lease on every exit path that left it held, writing `available:false` +
`released_utc` but NO live lease -- the scheduler keeps avoiding the unverified unit while a
re-run reclaims it immediately. A failed unit only becomes `available:true` after a
successful provision. A dead WinRM session (the network-drop case) cannot write the release
and is covered by the reclaim path on the next run.

**Implications:** availability.json no longer blocks the driver from re-provisioning; the
science-scheduler contract (`available:false` means "do not observe") is unchanged, and a
half-provisioned unit stays `available:false` until a clean run. This is the availability-lease
item of `MAST_provisioning#10` (autonomous-loop activation batch); it removes one of the manual
"delete the sidecar and re-run" interventions that unattended cadence would otherwise hit
constantly.

---

## [2026-07-09] Registry timezones stay IANA; the driver maps IANA->Windows for 5.1

**Why:** `unit-registry.json` stores IANA timezone ids (`Asia/Jerusalem`), but the driver
runs under Windows PowerShell 5.1 (.NET Framework 4.x), whose `TimeZoneInfo.FindSystemTimeZoneById`
only knows Windows ids and has no `TryConvertIanaIdToWindowsId` (that arrived in .NET 6). The
lookup therefore threw and `check-and-provision.ps1` silently fell back to server-local time --
defeating the already-shipped maintenance-window enforcement. It only looked fine because the
prov server is itself in Israel; on a differently-zoned (or Linux) server it would mis-time every
window. Observed in production on mast01/mast03 2026-07-06 (`MAINT_TZ_WARN ... 'Asia/Jerusalem'
was not found`). The setup doc compounded the drift by telling operators to use Windows names
(`tzutil /l`) while the live registry used IANA.

**What:** Keep IANA as the canonical registry form (portable: .NET 6+/`pwsh`/a future Linux prov
server resolve IANA natively) and add a resolver, `server/lib/mast-timezone.ps1`, that the driver
dot-sources. `Resolve-TimeZoneInfo` tries the id directly first (a valid Windows id, or IANA under
.NET 6+), then falls back to a small curated IANA->Windows map for the 5.1 path, and throws if the
id resolves under neither. `Test-InMaintenanceWindow` calls it instead of `FindSystemTimeZoneById`
directly; the `MAINT_TZ_WARN` fallback now fires only for a genuinely unresolvable id. Chose the
mapping layer over storing Windows ids in the registry to preserve the Linux-portability direction
in `autonomous-provisioning-requirements.md`. Pester coverage in `server/tests/mast-timezone.Tests.ps1`;
the setup doc now prescribes IANA.

**Implications:** A new fleet timezone must be added to the map in `mast-timezone.ps1` (a raw
Windows name still passes through, but IANA is canonical). This is the gating timezone fix from
`MAST_provisioning#10` (the autonomous-loop activation batch); consider promoting the
`MAINT_TZ_WARN` fallback to a hard failure once the unattended loop makes windows load-bearing,
so a mis-resolved zone stops rather than silently provisions at the wrong hour.

---