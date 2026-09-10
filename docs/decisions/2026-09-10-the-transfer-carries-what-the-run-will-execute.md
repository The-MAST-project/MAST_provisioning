---
decided: 2026-09-10
status: accepted
issue: MAST_provisioning#186
areas:
  - transfer
  - providers
  - drift
  - orchestration
---

# The transfer carries what the run will execute, and the build records who owns each asset

**Why:** every non-skipped run moved the whole payload to every unit. Measured on `run-20260902-141826`: 542 files, 14,877,375,466 bytes per unit, of which the `mast-indexes` astrometry seed is 10,575,826,560 — 71% — and `provide-imdisk.ps1` logs `reusing as-is` and never opens it once a unit's sparse image exists. Targeting already narrowed everything else: `drift.classify` yields per-module targets, `execute-mast-provisioning.ps1` filters commands by module, and `Driver._process_unit` narrowed smoke to `executed = target_modules or modules` when targeting landed. Transfer was the last phase still working from the full set, and it is the expensive one.

**What:** the build records attribution; the driver subtracts.

`build/build-staging-lib.ps1` gains `New-MastStagedPayloadMap`, `Add-MastStagedPayload` and `Test-MastCommandFileIsAsset`. `build-mast.ps1` calls them at the eight places it already knows which module it is staging for — the `commandfiles` flatten loop and the seven module-gated bulk blocks (`nomachine.lic`, `sxs\`, `wheels\`, `mast-indexes\`, `full-frame.fits`, the PlateSolve3 catalog pair, `cygwin-pkg-cache\`) — and emits the result as `build-manifest.json`'s **`module_payload`**, beside `always_modules`. `ConvertTo-Json` moved from `-Depth 4` to `-Depth 6`, which the nested arrays need.

`server/prov/payload.py` inverts that map to entry -> claimants and returns the entries **no** targeted module claims. `Driver._process_unit` computes them after `_filter_targets`, so the exclusion set reflects `--modules` as well as drift, and `_transfer` turns them into robocopy `/XD` and `/XF` arguments via `Get-MastRobocopyExclusionArgs` in `client/mast-pull-staging.ps1`, with `-ExcludeFiles` / `-ExcludeDirs` added to `prov.transport.pull_staging_args`. `staging_payload_size` takes the same exclusions so `-PayloadBytes` — the unit's disk guard — describes what is actually coming. A trimmed run logs `TRANSFER_TRIMMED` with the excluded names and the bytes skipped.

**The build still builds and declares the full set.** `fully_provisioned` is judged against `build-manifest.json`'s `modules`, so a subset build makes it read true over a partial set and publish the aggregate `payload_hash` with it — #63, and `2026-08-11-modules-filters-execution-and-never-the-build.md`. Nothing here builds a subset; only what crosses the wire is reduced. This will keep looking like a violation of that record, which is why it is stated here.

Three properties carry the safety:

- **Recorded, not declared.** The build writes down what it actually staged rather than reading a key a module author has to remember. There is no second list to keep in step, which is the failure `"always": true` was chosen to avoid in `2026-08-02-per-module-drift-decides-what-runs.md`.
- **The manifest is complete, and the build refuses to emit an incomplete one.** Every staging-root entry is recorded exactly once: under `module_payload` against its claiming module(s), or under `payload_always` for what every run needs regardless — the client scripts, each provider's non-asset `commandfiles`, the repofiles, `commands.json` and `build-manifest.json`. `Get-MastUnattributedStagedEntries` finds what neither named, and `build-mast.ps1` **throws** on a non-empty result. `prov.payload.exclusions` likewise raises `IncompletePayloadManifestError` rather than guessing.

  The first shape of this had a catch-all instead: an unrecorded entry always shipped, on the argument that the safe failure is a wasted copy rather than a missing file. That argument is sound and the property is still true of a *run* — but the failure is silent, and it hid two staging blocks within the hour. A dry-run classification of mast07 showed 2.086 GB still crossing, 2.07 GB of it the PlaneWave PlateSolve3 catalog: a seventh module-gated block, missed when the other six were enumerated, and invisible because nothing broke. Making completeness mandatory then immediately found an eighth — `config-bootstrap`'s `sites\`, whose nested non-asset `commandfiles` stage under a root *directory* rather than by leaf name (`Get-MastStagingRootName`). A catch-all that hides bugs at 2 GB a time is not a safety feature.
- **An empty target set excludes nothing.** `--force`, the `MODULE_DRIFT_NONE` fallback and a first provisioning all reach transfer with no targets, and one rule in `prov.payload.exclusions` covers all three — mirroring `_filter_targets` reading an empty list as the full set. No `if self.cfg.force` anywhere.

**Scripts are never excludable**, which is what `Test-MastCommandFileIsAsset` exists to say: only `assets/*` entries are recorded. `run-verify-only.ps1` is operator-run, defaults to every verify command in `commands.json`, and writes the tier-2 `validation.json` that drift reads — so a payload missing an untargeted module's `verify-*.ps1` would fail that module there and manufacture `needs-repair` on a healthy unit. Checked rather than assumed against the real fleet manifest: no `verify-*` file is recorded, and no module's `verify` command names any recorded asset. `verify-astrometry.ps1` reads `C:\MAST\full-frame.fits` and `D:\mast-indexes` — the installed locations, not staging — which is the property the whole design rests on.

**The two ways of saying "send everything" are equal by construction, and that is the test.** `--force` sends the whole payload by the empty-target rule; targeting every module sends it by attribution alone. With a catch-all they could differ and nothing would say so, because an entry no rule named still arrived. `test_force_and_targeting_every_module_transfer_the_same_set` asserts it on a fixture, `test_force_and_a_fully_targeted_run_send_the_same_thing` at the driver's wire, and a real mast07 build confirms it end to end: 170 staging-root entries, 170 recorded, none unrecorded and none recorded that is not there; `--force` and all 32 modules targeted both transfer all 170, byte-identical at 14,877,432,438.

Measured on mast07 (installed 2026-09-02, four modules drifted — `bootstrap-reassert`, `proxy`, `mast`, `desktop-shortcuts`; eight targets with the always-modules folded in): **110 files and 20 MB instead of 543 files and 14.877 GB, 99.9% less**.

**Rejected:**

- **Declaring the bulk directories in `module.json`** (a `payloaddirs` key collected like `always_modules`). The first shape of this change, and rejected once it was clear the build already has the module name and the destination path on the same line at every staging site: a declaration is a second statement of a fact the build performs, and it can disagree with what was staged. Recording cannot. It also would have covered only the six directories, leaving the ~20 root installers to a separate mechanism.
- **Bare names in `/XF` and `/XD`.** robocopy matches a bare name anywhere in the tree, so excluding `requirements.txt` for an untargeted `jupyter` would also drop a same-named file inside a directory a targeted module needs. Each entry is rooted at `$SrcUNC`, which confines the match to the staging root — the same scope `staging_payload_size` measures, so the two cannot disagree.
- **A comma-separated exclusion list.** Commas are legal in Windows filenames and would eventually split one in half. `|` is among the characters Windows forbids outright, so no asset can contain the separator.
- **Passing the exclusions as `[string[]]` parameters.** `test_pull_staging_args_match_the_script` finds emitted flags with `-(\w+) '`, so an array argument would be invisible to the drift guard the pull script's argument list depends on — the same reason `-PayloadBytes` is quoted despite being numeric.
- **Defaulting `skip` on `_transfer`.** It has one caller; a default is an invitation to add a second that forgets to trim.
- **Waiving `C901` on `staging_payload_size`** when the exclusion pushed it to 11. Per-function waivers are available (`2026-08-18-c901-is-waived-per-function-not-per-file.md`) and were not needed: a directory and a file cannot share a name inside one directory, so both exclusion lists merge into one set that filters the root's entries once, and the per-entry branching disappears.
- **A catch-all for unrecorded entries.** Kept for the first day of this change and then removed; the argument is above. What replaces it is not optimism but a build that cannot emit a manifest it does not fully describe.
- **Excluding at build time instead** — not staging the untargeted modules' assets at all. It is the same prohibited subset build wearing different clothes: the payload's contents are what `payload_hash` and `fully_provisioned` are computed from.

**Unsettled:**

- **`--force` gets nothing from this**, and neither does a first provisioning. Both still move the full payload, and `--force` is what the 2026-09-02 fleet run used. Tier 2 on #186 — a durable destination so robocopy computes a real delta — is what covers them.
- **The index seed still ships whenever `imdisk` is targeted**, even to a unit whose image exists and which will therefore not read it. That is module granularity doing its job; the seed's need is a property of unit state, not of the module. #186 option B.
- **`TRANSFER_OK` still reports a pre-scan rather than a measurement (#189).** Behavior is unchanged here, but expected bytes now vary per unit, so a short transfer can no longer be spotted against a known constant. `TRANSFER_TRIMMED` states the intent in the log as a partial mitigation; the real fix is that issue.
- **Two provider-internal `.ps1` files live under `assets/` and are therefore recorded** — `mast-mount-shared.ps1` and `fix-perf-counters.ps1`. Both are run only by their own module's `provide` script, so excluding them with that module is correct, but it means "scripts always ship" is true of `commandfiles` scripts specifically, not of every `.ps1` in a payload.
