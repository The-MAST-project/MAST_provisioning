# Retire the `mast` provider's clone/venv code in favor of `mast-clone` — plan

> **COMPLETE — archived 2026-08-09.** Every stage landed, and stage 6 (the on-unit
> migration) ran on all four production units: mast01 and mast04 on 2026-08-06,
> mast02 and mast03 on 2026-08-09, each verified with `mast-verify` passing and
> `IN SYNC` in `tools/fleet-drift-report.py`. The one-time machinery this plan
> describes — `tools/migrate-unit-to-mast-clone.py`, `server/prov/migration.py`,
> the `verify-mast` legacy-tree check, and the NSSM re-point branch in
> `provide-mast.ps1` — was deleted the same day (#41).
>
> **Kept as a design record, not as instructions.** Nothing here should be
> followed: the stages are done and the tooling to execute them is gone. It is
> retained because several providers cite it for *why* they call `mast-clone`
> rather than clone anything themselves, and because it is the fullest account of
> that reasoning. The outcomes are recorded individually under `docs/decisions/`
> (the 2026-08-02 and 2026-08-03 records on mast-clone delegation, the upstream
> repo pin, and the stage-6 rename).

Branch: `eli/mast-clone-adoption` (off `eli/provisioning-v3`), landing back onto
v3. Tracking issue: The-MAST-project/MAST_provisioning#31.

## Goal

Provisioning stops carrying its own repo-cloning and venv-building code and
calls **`tools/mast-clone.ps1 -Role unit`** instead — the tool Arie built, which
already serves the control host and dev boxes. One implementation of "lay out
the MAST repos and build their environment," one manifest
(`tools/mast-repos.tsv`), one resolver, for every machine in the fleet.

The endgame this unlocks: once every live unit runs the mast-clone layout, the
**`MAST_common` submodule can be retired entirely** — provisioning is its last
consumer that needs it populated.

## Baseline (what exists today)

`server/providers/mast/provide-mast.ps1` (order 2200) does all of the following
itself, on the unit:

- reads its own repo manifest `mast-repos.txt` via `mast-repo-list.ps1`;
- clones each repo into `C:\MAST\repos\<RepoName>\`, injecting a GitHub token
  into the remote URL (`https://x-access-token:<token>@github.com/...`) read
  from a staged `mast_github.txt` — this is issue #17;
- runs `git submodule update --init --recursive`, which populates
  `MAST_unit.2024-12-12\src\common` from the `MAST_common` submodule;
- creates a **per-repo** venv at `<repo>\.venv` (`python -m virtualenv`, falling
  back to `python -m venv`), runs an unpinned `pip install --upgrade pip`, then
  `pip install -r requirements.txt` **per repo, separately**;
- registers the `mast-unit` NSSM service, opens the TCP 8000 firewall rule, and
  restarts the service after an update.

`verify-mast.ps1` is presence-only: repo dir, `.git`, `.venv\Scripts\python.exe`,
service running.

## What `mast-clone` does instead

`tools/mast-clone.ps1` + `tools/mast-clone.sh` (Windows / Linux, one shared
manifest `tools/mast-repos.tsv`), on `main` as of `7b37560`:

- **Manifest-driven** — `mast-repos.tsv` maps `dir → repo → roles → branch`.
  Adding a repo is a row; neither script hardcodes a list. Branches are pinned
  explicitly, with the reasoning recorded in the file: `MAST_common` and
  `MAST_control` both have an abandoned 2-commit `main` as their GitHub default
  while real work is on `master`, so a plain clone lands on a stub.
- **Flat role-scoped layout** under `<Top>`: `common\`, `unit\`, `claude\` for
  role `unit`. `MAST_common`'s repo root *is* the `common` package (root
  `__init__.py`), so cloning it to a folder named exactly `common` and putting
  `<Top>` on `sys.path` makes every existing `from common.X import ...` resolve
  with **no source changes and no submodule**.
- **One venv** at `<Top>\.venv`, built with **uv pinned by the manifest**
  (`#!uv-version 0.11.33`), bootstrapped checksum-verified from the GitHub
  release (never `irm | iex`, never "latest").
- **One joint resolve** — every requirements file for the role goes into a
  single `uv pip install` invocation, so two repos that pin the same package
  differently fail loudly instead of letting the last file win.
- `mast.pth` in the venv's site-packages wires `<Top>` onto `sys.path` —
  deliberately not `PYTHONPATH`, because the MAST code runs as NSSM services
  which do not inherit a shell environment.
- **Guards we currently lack**: a `common\__init__.py` check that fails at
  provisioning time rather than at service start on a dark unit; a shadowing
  check for a stray `__init__.py` in a consumer repo root; idempotent re-runs
  that never merge over local work.
- **Disarms** the vestigial `common` submodule in each consumer clone
  (`submodule.common.update=none`, local config only, so the tree stays clean).

## Locked decisions

1. **`mast-clone` is the single implementation.** `mast-repos.txt` and
   `mast-repo-list.ps1` are deleted; `tools/mast-repos.tsv` is the only repo
   manifest. Provisioning keeps only what mast-clone does not do: NSSM service
   registration, the firewall rule, and restart-on-update.
2. **Anonymous HTTPS; the GitHub token is deleted, not re-plumbed.** All seven
   The-MAST-project repos are **public** (verified 2026-08-02), so
   `-Transport https` needs no credentials. `provide-mast.ps1` is the token's
   only consumer, so the whole token path goes with it — see Stage 2.
3. **`<Top>` is `C:\MAST\src`** — mast-clone's own documented example, a sibling
   of the existing `C:\MAST` state tree (logs, manifests, smoke markers).
   Load-bearing: it appears in the NSSM service definition and in the migration.
4. **Do this before per-module-tracking Stage 1b** (#22). 1b is specified against
   `mast-repos.txt`, which this deletes; implementing it first means writing it
   twice. See "Interaction with #22" below.
5. **Migration is a supervised one-shot, not part of the autonomous loop**
   (Stage 6). The migration stops a service, moves the code root, rewrites the
   service definition and deletes the old tree — destructive, one-time work that
   should not live in the routine cycle forever. `verify-mast.ps1` fails loudly
   on the old layout instead, so the loop refuses to touch an unmigrated unit
   rather than half-updating it.
6. **A dirty working tree is a verify failure, not a silent skip.** mast-clone
   fast-forwards only and refuses to merge over local work — safer than today's
   `reset --hard FETCH_HEAD`, but the failure mode inverts: a unit carrying a
   stray edit quietly stops receiving updates. `verify-mast.ps1` reports a dirty
   tree as a failure so "the fleet is up to date" keeps meaning what it says.
7. **The GitHub token is removed entirely**, not kept dormant against a future
   private repo. An unused credential that nothing exercises is the kind that
   rots and leaks. Accepted cost: a repo going private later is a re-plumbing
   job, not a config flip.
8. **#17 closes from this epic, with an explicit pointer comment** — but at
   Stage 6, not Stage 2; see the note under Stage 2 for which of its three
   actions each stage actually discharges.
9. **The provisioning-facing tests are in scope, including drift alarms on
   `mast-clone` itself.** See "Test ownership" below — this is the mitigation for
   the ownership-shift risk, not an optional extra.

## Token removal: scope and where it happens

Expiry (2026-08-02) ends the live exposure. What remains to remove is **the
token's use** — the places that authenticate with it — not every on-disk copy of
the string. Incidental residue (git trace logs, archived session logs, old
staged payload copies under `C:\mast-staging\<run-id>\`) is explicitly **out of
scope**: it is inert, and this is a hygiene change, not an incident response.

Two uses, each removed by a stage below — **no separate manual scrub**:

1. **The build and provision code paths that read and inject it** — the
   `mast_github.txt` read and `Get-MastGitHubHttpsCloneUrls` in
   `provide-mast.ps1`, and the vault staging copy in `build-mast.ps1`.
   **Stage 2.** This is what stops the use recurring.
2. **The `origin` remote URL on each deployed unit** —
   `C:\MAST\repos\<repo>\.git\config` carries the
   `https://x-access-token:<tok>@github.com/...` form. **Stage 6**, which
   re-clones every repo through mast-clone into `C:\MAST\src` (tokenless by
   construction — mast-clone has no token path at all) and deletes
   `C:\MAST\repos` outright. Hand-editing those remotes first was considered and
   dropped: it is work on trees the migration deletes anyway.

**State of the deployed units, surveyed 2026-08-02** (read-only; nothing
changed). All four reachable; `origin` is the only remote on each.

| Unit | `MAST_common` origin / branch | `MAST_unit.2024-12-12` origin / branch |
|---|---|---|
| mast01 | tokenized, **retired fork** `elibrody-weizmann` / `eli/vm-provisioning` | tokenized, `The-MAST-project` / `main` |
| mast02 | tokenized, **retired fork** / `eli/vm-provisioning` | tokenized, `The-MAST-project` / `main` |
| mast03 | tokenized, **retired fork** / `master` | tokenized, `The-MAST-project` / `main` |
| mast04 | tokenized, **retired fork** / `eli/vm-provisioning` | tokenized, `The-MAST-project` / `main` |

Two consequences for Stage 6, both arguing it should not slip:

- **`MAST_common` on every unit still points at the retired fork**, and three of
  the four sit on `eli/vm-provisioning` — a branch deleted with the fork. Those
  three cannot fetch `common` at all today, token or no token. The migration is
  what repairs it.
- mast02 additionally carries `mast-claude-config` (already tokenless) and a
  `PlaneWave_PlateSolve3_Catalog` directory under the same root; the migration's
  `C:\MAST\repos` deletion must account for both rather than assuming the two
  standard clones.

## Stages

### Stage 0 — Merge `main` into v3

`eli/provisioning-v3` is 20 ahead of `origin/main` and 6 behind; `mast-clone`
lands on v3 with that merge. Nothing else in this plan can start first.

### Stage 1 — Stage repo-top files into the payload (`repofiles`)

The staging pass resolves a `commandfiles` entry as
`Join-Path $providersRoot $module $cmdfile`. A `../../tools/mast-clone.ps1`
entry would resolve on the *source* side but write **outside** the staging root
on the destination side, and copying the scripts into the provider dir at build
time would defeat the single-source-of-truth this whole change is for.

- Add a **`repofiles`** key to `module.json`: paths relative to the repo top,
  staged to the staging root **by leaf name** (the same flattening `assets/*`
  already gets). The `mast` module declares
  `["tools/mast-clone.ps1", "tools/mast-repos.tsv"]`.
- `repofiles` are **inside the per-module hash boundary** — they are as much a
  determinant of the module's deployed output as its `commandfiles`
  (Resolution rule 1 in `per-module-tracking-plan.md`). Extend
  `Get-ModuleContentHash` accordingly.

  **Closed 2026-08-02.** `Get-ModuleContentHash` gained `-RepoTop` / `-RepoFiles`
  and emits `repofile:<path>:<sha>` lines, so a change to `tools/mast-clone.ps1`
  drifts the `mast` module rather than only the aggregate `payload_hash`. This
  could not be done when Stage 1 landed — `build/build-manifest-lib.ps1` was #22
  Stage 1 and had not reached `eli/provisioning-v3`; merging v3 in after #33
  landed unblocked it. A missing repofile throws rather than hashing a gap
  (unlike a commandfile it can never be a `-TestMode` optional payload), and a
  module declaring no repofiles keeps its previous hash.

**Status:** landed — `build/build-staging-lib.ps1`, the staging loop in
`build-mast.ps1`, `server/tests/build-staging-lib.Tests.ps1`, README schema
note, docs/decisions/2026-08-02-repofiles-stage-shared-tooling.md. Hash coverage deferred as described. **The Pester
suite has not been run** — this branch was developed on macOS, which has no
PowerShell; run `Invoke-Pester -Path server\tests\build-staging-lib.Tests.ps1`
on the Windows provisioning box before merging.

### Stage 2 — Delete the GitHub token path

Removes the secret rather than handling it better. All target repos are public,
so nothing authenticates.

**Which of #17's three actions this discharges — read before closing it.** #17
asks for (a) rotate the exposed token, (b) scrub it from existing unit
checkouts, (c) stop embedding it at the source. **This stage is (c) only.**

- **(a) is already discharged: the token expires 2026-08-02**, so the exposed
  credential dies on its own and there is nothing to rotate. What remains on the
  units is an inert string.
- **(b) happens in Stage 6**, which re-clones through mast-clone (no token path)
  and deletes `C:\MAST\repos`. Read as "stop the deployed units using the
  token", per the scope agreed 2026-08-02.

**The expiry does not break provisioning**, because the repos are public and
GitHub *ignores* invalid credentials on a public repo rather than rejecting the
request — verified 2026-08-02 against both `MAST_common` and
`MAST_unit.2024-12-12` with a bogus token in the URL: `git ls-remote` succeeds
and serves the refs anonymously. So the existing token-in-URL clone path keeps
working after expiry, and neither this stage nor Stage 6 is urgent on that
account. (Had the repos still been private, expiry would have broken every unit
clone and fetch the moment it landed.)

- `provide-mast.ps1`: drop the `mast_github.txt` read and
  `Get-MastGitHubHttpsCloneUrls` (the token-in-remote-URL builder that #17 is
  about).
- `build/build-mast.ps1`: drop the `vault\tokens\mast_github.txt` staging copy,
  the `-AllowMissingGithubToken` switch, and the `-TestMode` optional-payload
  exception for `assets/mast_github.txt`.
- Remove the token from `vault/README.md`, `README.md`, and
  `docs/provisioning-server-setup.md` §2b. Leave the `.gitignore` rule in place
  — it costs nothing and still guards against a re-introduction.
- `autonomous-provisioning-requirements.md`: retire **Exception #3** (GitHub
  token) and row 12 (MAST application repo authentication) — both become
  non-applicable rather than "needs scenario".
- **Note:** a token is still required to clone *private* repos. If any MAST repo
  goes private again, this decision reverses and mast-clone needs a credential
  path (an org-scoped `url.<...>.insteadOf` rewrite, not a token in the remote
  URL). Recorded so the reversal is a deliberate act, not a surprise.
- **Tests:** a build with no vault token succeeds and stages no token file;
  no staged artifact contains a token-shaped string.

### Stage 3 — Rewrite `provide-mast.ps1` around `mast-clone`

- Replace the clone / submodule / venv / pip blocks with one invocation:
  `mast-clone.ps1 -Top C:\MAST\src -Role unit -Transport https -Update`.
  `-Update` gives the fast-forward-on-re-run behavior that the current pull path
  approximates with `fetch` + `reset --hard FETCH_HEAD` (mast-clone is safer: it
  refuses to fast-forward a dirty tree instead of discarding it).
- Delete `mast-repos.txt` and `mast-repo-list.ps1`.
- **Re-point the NSSM service** — all three of its coordinates move:

| | today | after |
|---|---|---|
| interpreter | `C:\MAST\repos\MAST_unit.2024-12-12\.venv\Scripts\python.exe` | `C:\MAST\src\.venv\Scripts\python.exe` |
| entry point | `...\MAST_unit.2024-12-12\src\app.py` | `C:\MAST\src\unit\src\app.py` |
| `AppDirectory` | `...\MAST_unit.2024-12-12` | `C:\MAST\src\unit` |

- Keep the firewall rule and the restart-after-update behavior unchanged.
- **Sweep for hardcoded `C:\MAST\repos`** across every provider, the diagnostics
  tooling, desktop shortcuts, and any scheduled task. This is a required step,
  not a spot check: a missed reference is a module that silently points at a
  tree that no longer exists.
- **Verify the import path before promising submodule retirement.** Today unit
  code reaches `common` through the populated submodule at `src\common`; after
  the relayout it resolves from `<Top>` via `mast.pth`. Confirm on a real unit
  that no import depends on the `src\common` location specifically.
- **Tests:** command construction (role, top, transport); service definition
  points at the new paths; no surviving reference to `C:\MAST\repos`.

**Status:** landed 2026-08-02. Also swept: the two validation providers
(`mast-validation`, `mast-autofocus-validation`) resolved the unit clone and its
venv under `C:\MAST\repos`; both take `-MastTop` now. `pull-mast-repos.ps1`
deleted -- already unreferenced, and superseded by `mast-clone -Update`. A real
build on labcomp2 staged both repofiles and confirmed a `mast-clone.ps1` edit
moves `module_state.mast.hash`.

### Stage 4 — Stage a pinned `uv.exe` into the payload

mast-clone prefers an existing `<Top>\.tools\uv.exe` over bootstrapping one, so
this needs **no change to Arie's script**: stage the pinned uv as a payload
asset and drop it at `<Top>\.tools\uv.exe` before invoking mast-clone.

Removes a provision-time network dependency on the GitHub releases CDN and makes
the resolver version a build-side fact rather than a download. Same precedent as
the frozen cygwin package cache (#20). The staged binary's version must match
the manifest's `#!uv-version` — assert it, don't assume.

**Status:** landed 2026-08-03. The **zip plus the publisher's `.sha256`** is
vendored rather than the extracted `uv.exe` — 18 MB against 46 MB in git and in
every payload, and the checksum keeps the integrity check mast-clone's own
bootstrap performs. `build/fetch-uv.ps1` refreshes it and reads the version from
`tools/mast-repos.tsv`, so the artifact and the pin cannot be bumped
independently. Verified on labcomp2: a production build stages both files, and
checksum + extract + `uv --version` yields 0.11.33 matching the pin, at the path
mast-clone probes.

### Stage 5 — Rewrite `verify-mast.ps1` for the new layout

- Presence checks move to the new layout: `<Top>\.venv`, `<Top>\common`,
  `<Top>\unit`, plus the `mast-unit` service.
- Make it **content-aware** (this is per-module-tracking Stage 4's highest-value
  verify, now much simpler than planned — one venv instead of N):
  `git rev-parse HEAD` per cloned repo against the recorded SHA, and
  `uv pip freeze` in the single venv against the joint resolve.
- **Fail on a dirty working tree** (locked decision 6). mast-clone declines to
  fast-forward one and moves on; without this check that unit silently freezes
  at whatever commit it was on. A dirty tree on a production unit is an
  incident, not a state to tolerate quietly.
- **Fail on the old layout** (locked decision 5) — an unmigrated
  `C:\MAST\repos` tree, or a `mast-unit` service still pointing into it, is a
  loud failure so the autonomous loop refuses the unit instead of half-updating
  it.
- **Tests:** a stale repo HEAD fails; a package off its pin fails; a dirty tree
  fails; an old-layout unit fails; a clean migrated unit passes.

**Status:** landed 2026-08-02 alongside stage 3 -- deleting `mast-repos.txt`
forced the rewrite, since the old verify read its repo list from it.

### Stage 6 — Migrate mast01–04 (supervised one-shot)

A **one-shot migration script, run under supervision, one unit at a time** — not
folded into the autonomous cycle (locked decision 5). Per unit: stop `mast-unit`
→ run mast-clone into `C:\MAST\src` → re-point the NSSM service → verify →
**then** remove `C:\MAST\repos`.

The removal is not optional cleanup, and it does two jobs. Leaving the old tree
in place is exactly the stale-second-copy hazard mast-clone's submodule-disarming
comment describes — a second `common` that can win on `sys.path`. It is also
what discharges **#17 action (b)**: the token lives in
`C:\MAST\repos\<repo>\.git\config`, and deleting the tree is what removes it
from the unit. Verify the token is gone post-migration rather than assuming it.

**#17 closes here** — Stage 2 stopped the recurrence, and this stage is what
takes the token off the deployed units, since the re-clone is tokenless by
construction and `C:\MAST\repos` goes away with it.

- **Tests:** old-layout detection; the script is a no-op on an already-migrated
  unit; it refuses to delete `C:\MAST\repos` before the new layout verifies
  clean (never leave a unit with neither tree working).

**Status:** landed 2026-08-03 as `tools/migrate-unit-to-mast-clone.py` +
`server/prov/migration.py` + 13 tests. Dry-run by default; **renames** to
`repos.retired-<stamp>` rather than deleting (reversible on a production unit),
with `--purge` for an outright delete. Rehearsed end-to-end on the dev VM: dry
run `ready`, `--apply` migrated cleanly, and the following provisioning cycle
gave the first fully clean `mast` verify. mast01-04 not yet migrated.

## Interaction with #22 (per-module tracking)

- **Stage 1b of `per-module-tracking-plan.md` must be re-specified** against
  `tools/mast-repos.tsv` (filtered to rows whose `roles` include `unit`) instead
  of `mast-repos.txt`, and should fold the manifest's `#!uv-version` directive
  into the hash as another output determinant — already pinned and checksummed,
  so it costs nothing.
- **The unpinned-`pip` determinant flagged in the 2026-08-02 amendment
  disappears.** mast-clone uses pinned uv with one joint resolve, the same path
  the control host takes, so the unit/control resolver divergence resolves by
  adoption rather than by a decision.
- **Stage 4 of #22 gets simpler** — one venv to interrogate, and `uv pip freeze`
  against a joint resolve is a single well-defined comparison.

## Risk: ownership shifts

Unit provisioning would depend on a tool whose primary consumer is Arie's dev
workflow, so a `mast-repos.tsv` branch-pin edit becomes a fleet-affecting
change. That is the price of the single source of truth and is the right trade
— but it is only an acceptable trade *because* of the test ownership below.

## Test ownership (in scope, locked decision 9)

Two kinds of test, and the second is the one that makes the ownership shift
safe.

**1. Provisioning's own behavior** — the ordinary suite for Stages 1, 3 and 5:
`repofiles` staging, mast-clone command construction, the three NSSM service
coordinates, no surviving `C:\MAST\repos` reference, the verify checks
(stale HEAD, off-pin package, dirty tree, old layout), migration-script
idempotence.

**2. A dev-drift alarm on `mast-clone` itself.** A change made to
`tools/mast-clone.ps1` or `tools/mast-repos.tsv` for **development** reasons
must not silently change what a unit receives. Provisioning therefore pins the
part of the tool it depends on, and the test suite fails when that part moves:

- **Golden manifest snapshot for `roles ∋ unit`.** Assert the exact set of rows
  the `unit` role resolves to — `dir`, `repo`, `branch` per row — plus the
  `#!uv-version` directive, against a checked-in expected snapshot. A dev
  retargeting `unit` at a feature branch, adding a repo to the role, or bumping
  uv then fails the provisioning suite, and updating the snapshot is the
  deliberate act that acknowledges a fleet-affecting change.
- **Contract test on the invocation surface.** Assert the parameters
  provisioning relies on still exist and behave: `-Top`, `-Role`, `-Transport`,
  `-Update`, `-DryRun`; the `<Top>\{common,unit,claude}` layout for role `unit`;
  the preference for an existing `<Top>\.tools\uv.exe` over bootstrapping
  (Stage 4 depends on it); the `mast.pth` write. Best driven through
  `-DryRun`, which prints the planned actions without touching anything.
- **Whole-file checksum of `mast-clone.ps1`** as a coarse backstop, so *any*
  edit surfaces in review even where no assertion covers it. Cheap, and it
  turns "someone changed the tool" from something noticed after a bad
  provision into a failing test. Update it in the same commit that reviews the
  change.

The point is not to freeze Arie's tool — it is that every change to it passes
through a provisioning review gate before it reaches a unit.

Secondary: mast-clone writes a `mast-<role>.code-workspace` and VS Code
extension recommendations — dev-oriented and inert on a headless unit. Harmless;
noted so it is not mistaken for a defect during migration.

## Retiring the `MAST_common` submodule (gated, out of scope here)

mast-clone only **disarms** the submodule; it does not remove it. Full
retirement means deleting the gitlink and the `.gitmodules` entry from
`MAST_unit.2024-12-12`, `MAST_control`, `MAST_gui` and `MAST_spec` — upstream
work in those repos, not provisioning.

**Gate:** every live unit running the mast-clone layout (Stage 6 complete), and
the Stage 3 import-path verification passing on a real unit. Provisioning is the
last consumer that needs `common` populated as a submodule; once it is not, the
gitlink is dead weight in four repos.

## Documentation (required)

- `DECISIONS.md` entry per landed stage.
- `autonomous-provisioning-requirements.md`: retire Exception #3 and row 12
  (Stage 2); update the manifest/repo-layout sections for the new tree.
- `README.md` + `docs/provisioning-server-setup.md`: drop the token setup step,
  document `C:\MAST\src` as the unit code root.
- Amend `docs/per-module-tracking-plan.md` Stage 1b once this lands.

## Out of scope (tracked elsewhere)

- **#22** per-module tracking Stages 1b–4: sequenced *after* this.
- **#25** `Z:` is the unit's operational drive — unrelated, but touches the same
  unit-side path assumptions; do not conflate.
- Linux-side (`mast-ns-control` / `mast-ns-spec`) adoption of `mast-clone.sh`:
  already Arie's path, no provisioning change needed.
