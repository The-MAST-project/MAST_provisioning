---
decided: 2026-08-11
status: accepted
issue: MAST_provisioning#63
areas:
  - providers
  - drift
  - orchestration
  - failure reporting
---

# `--modules` filters execution and never the build

**Why:** `fully_provisioned` is the fleet's "this unit is completely provisioned" signal — the gate #41's deletions were held against, and what the drift report and any future "is everything current" question rest on. It read **true off six modules** on mast03.

`Merge-MastInstalledManifest` judges the flag against `$BuildData.modules`, i.e. whatever the *build* declared. `driver.py` carried a comment asserting the build is always the full set, and explaining precisely why it must be:

> The build above is deliberately still the FULL module set: building a subset would make the payload's build-manifest declare only that subset, and the unit's `fully_provisioned` would then be judged against a partial set and read true on a one-module run. Targeting therefore happens at EXECUTE, not at build.

The comment was right about the consequence and wrong about the code. `_resolve_modules` honored `--modules`, and its result went straight into `_build` as `-Modules`, so the invariant the comment described was never enforced.

Measured by driving the merge directly on mast03 (PS 5.1.19041.4522), 8 declared modules, 1 touched:

| Build declares | Previous manifest | `fully_provisioned` | `payload_hash` |
|---|---|---|---|
| all 8 | none | False | absent |
| **only the 1** | none | **True** | **published** |
| all 8 | holds the other 7 | True | published |

Row 2 is what `--modules` produced. Because `payload_hash` is published with it, a *repeated* identical subset run then satisfied both halves of the skip condition — `report.current` (every module the subset build declared was present and matching) and `aggregate_matches` — and the unit was logged `UNIT_SKIP already_current` having never been checked against the full set.

A further discovery shaped the fix: **`--modules` was never an execute-time filter.** It worked entirely by shrinking the build, after which drift classification compared against the smaller manifest. So "keep it as an execute-time filter" meant *writing* that filter, not moving it.

**What:** two seams instead of one.

`_resolve_modules(unit)` now returns the unit's **complete** set and ignores `--modules` entirely. A registry-declared `modules` list still wins over discovery — that list says what a given unit's full set *is*, which is a different statement from "run only these now."

`_filter_targets(targets, full_set)` applies `--modules` after the build and after classification: it intersects the classifier's targets with the named set (treating an empty target list, which means "run everything", as the full set), then re-adds the always-modules and orders the result. `_process_unit` calls it only when `--modules` is set, logging `MODULE_TARGET_FILTERED`.

`--modules` therefore no longer influences what is built, what `fully_provisioned` is judged against, or whether a unit is skipped as already current.

**Rejected:**

- **`--modules` as a targeted force** — skip classification, never skip the unit, run exactly the named set. It has a real argument: `--modules mast` on an already-current unit does nothing under the chosen semantics, which is probably not what an operator typing it expects. Rejected because it makes the flag mean two things at once (what to run *and* whether to override currency), and because a force already exists (`--force`) and composes with the filter.
- **Recording the full provider set in the build-manifest separately from the built subset**, and judging `fully_provisioned` against the former (option 2 on the issue). Keeps subset builds cheap. Rejected as more machinery for a build that is not the expensive part of a cycle, and because it leaves two module lists in the manifest for a future reader to confuse.
- **Making the merge function detect a partial build.** It cannot: nothing in a build-manifest distinguishes "these are all the modules" from "these are the modules I built." The invariant has to live in the caller, which is why a comment now says so at the point the flag is computed.
- **A Pester test asserting a subset build-manifest yields `false`.** That would assert behavior the merge deliberately does not have — per its contract a subset build *should* report true over that subset. The guard belongs on the Python side, where the subset could be produced.

**Unsettled:**

- **`MODULE_TARGET_EMPTY` skips rather than running the always-modules alone.** When nothing named needs work, the run stops. The reason is concrete: `reboot` is an always-module, so synthesising a run out of an empty intersection would reboot a unit for a run with no work in it. The cost is that `proxy` posture and `mast-services-finalize` also do not run in that case — which is right if the operator's narrow request was the whole intent, and wrong if they expected a normal cycle constrained to one module. No field case yet either way.
- **mast03 still asserts a false `fully_provisioned = True`** over its six recorded modules. Nothing in this change repairs an already-written manifest; a full run is what replaces it, and that has not been done.
- **The always-modules ride along on every filtered run**, so `--modules mast` restarts services and evaluates a pending reboot. Correct per #60, but it means the filter is never as narrow as it reads.
