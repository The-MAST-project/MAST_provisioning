---
decided: 2026-08-31
status: accepted
issue: MAST_provisioning#175
areas:
  - failure reporting
  - source-layout
  - drift
---

# A failed fetch is recorded by mast-clone and asserted by provide-mast

**Why:** mast05's bench reprov (`run-20260830-140322`) finished with the `mast` module green while the unit stayed on its previous `MAST_common` and `MAST_unit`. Three fetches had failed — `Could not resolve proxy: bcproxy.weizmann.ac.il` — and nothing anywhere said the code had not moved.

`tools/mast-clone.ps1` had one git call whose result was thrown away:

```powershell
$null = Invoke-Git @('-C', $dest, 'fetch', '--prune', 'origin')
```

`Invoke-Git` documents itself as returning `$true` on success and every other call site checks it. What made this particular omission invisible rather than merely sloppy is what runs next: `merge --ff-only @{u}` compares the checkout against a **remote-tracking ref the failed fetch did not move**, finds nothing to do, prints `Already up to date.` and returns success. So the failure did not merely go unreported — the run actively produced the output a clean run produces, on the one step whose entire purpose is to move the checkout. `clone-manifest.json` then recorded the stale SHAs in the same field a successful fetch fills, and `provide-mast.ps1`'s two post-conditions (venv interpreter present, unit checkout present) both held, because both did exist.

Two further instances were found while fixing it, neither in the report:

- The **pinned-rev path** discards two more fetch results (`fetch --tags --force`). The `checkout --detach` after them only fails when the rev is absent *locally*, so a tag force-moved upstream but not fetched checks out against the object this clone already had, and `resolved_sha` records it as the intended result.
- **`verify-mast.ps1` is blind to this by the same mechanism.** Its currency check is `rev-parse HEAD` against `rev-parse '@{u}'`, and `@{u}` is exactly the ref the failed fetch left stale — so `HEAD -eq upstream` and tier 2 logs `common: current at <sha>`. The check written to catch a stale checkout passes it. Left for its own issue: making verify fetch changes what tier 2 does on the network, and reading `fetch_ok` out of `installed-manifest.json` may be the better answer.

**What: the tool records, the provider asserts.**

`mast-clone` checks all three fetches, **skips the update** for a repo whose fetch failed (that is what removes the false `Already up to date.`), collects the repo into `$fetchFailures`, and reports it three ways — a warning at the failure, `[UNVERIFIED -- fetch failed]` on the per-repo summary line, and a tail warning listing every affected folder. The sidecar gains **`fetch_ok`** per repo, which is the field that was missing: `resolved_sha` alone cannot distinguish *"this is what origin says"* from *"this is what was already on disk and could not be checked"*, and that ambiguity is what let a stale SHA look like a result.

**`mast-clone` does not throw.** It is also the casual dev clone tool and the control host's, and refreshing an existing tree off-network is a legitimate thing to do there. Failing it would break workflows that have nothing to do with the fleet, to enforce a requirement only the fleet has.

So the assertion is `provide-mast.ps1`'s: it reads the sidecar after the call and throws when any repo reports `fetch_ok` false, joining the two post-conditions already there. A unit that could not reach GitHub is not provisioned to a known revision whatever is on its disk, so this is a failed run. It **fails closed on a missing `fetch_ok`**, not only on a false one — `mast-clone.ps1` ships in this module's own payload as a `repofiles` entry, so the two are always in step and a sidecar without the key means something else is wrong.

`fleet-drift-report.py` renders the new field as a `REPO_UNVERIFIED` state, glyph `?`, taking precedence over `DIFFERS` and `UNPINNED` because an unreachable remote is usually their cause rather than a separate finding. There it reads a **missing** `fetch_ok` as unknown-and-quiet, the opposite of the provider — it also reads units provisioned months ago, and marking every one of them unverified would bury the signal. The report reaches the sidecar for free: `execute-mast-provisioning.ps1` already folds the whole `repos` block into `installed-manifest.json`.

**`mast-clone.sh` is aligned to the same shape, which meant changing it.** The shell half was previously correct only by accident: under `set -euo pipefail` a bare failing fetch aborted the whole script, so an offline refresh produced no submodule disarm, no `clone-manifest.json` and no summary at all. Its fetches are now guarded explicitly and it carries on and records, like the ps1 half. The issue proposed treating the `.sh` as the reference for disposition; that reading was rejected once the disposition was settled — see *Rejected*.

**Rejected:**

- **A `-RequireFetch` / `-StrictFetch` switch on `mast-clone`,** with `provide-mast` opting in. The first design, and it fails closer to the failure: the module would stop before spending minutes creating and populating a venv it is going to discard. Rejected on the shared-tool requirement — a fleet-only policy inside a tool three other callers use is a parameter someone eventually passes by accident, and the switch has to be threaded through the provider's splat and the contract test's invocation surface to buy a few minutes. The latency is accepted instead: the sidecar is written before the uv work, so the assertion has its answer early and simply does not act on it until `mast-clone` returns.
- **Asserting in `mast-clone` unconditionally** (fail the tool, not just the module). Simplest diff, and it breaks dev and control-host use for a requirement neither has.
- **Aligning `mast-clone.sh` by leaving it alone,** as the issue suggested. It does satisfy the one invariant that matters — a failed fetch never reports success — but by aborting, so the two halves would have diverged on both disposition and sidecar shape while looking aligned. "The `.sh` is the reference" was right about the defect and wrong about the remedy.
- **Making the `verify-mast.ps1` blindness part of this change.** It is the same defect class in the same run and it is tempting to close both. It needs its own decision about whether tier 2 may touch the network, and bundling it would put two dispositions in one PR.
- **Treating a missing `fetch_ok` as a pass in the provider,** for symmetry with the drift report. The two read different populations: the provider reads a sidecar its own payload just wrote, the report reads whatever a unit has carried since. Symmetry here would mean the provider silently accepting the exact ambiguity the field exists to remove.

**Unsettled:**

- **Whether a bench unit can reach GitHub at all is still open, and this change does not answer it.** The mast05 error names the *campus proxy* as unresolvable, not GitHub as unreachable; the run used the default `--proxy-mode weizmann`, so git was told to use a proxy the unit could not resolve. `--proxy-mode direct` exists, was not tried, and `#136` says it always fails the unit for an unrelated reason. `#166` records mast08 holding a guest Wi-Fi address alongside its bench link, so a second path with internet may well exist. `server/providers/proxy/set-proxy.ps1` already probes `bcproxy:8080` and `github.com:443` side by side, so settling it is a short run on a reachable unit rather than an investigation. If some deployment legitimately cannot reach GitHub, this record's disposition is the wrong one and an explicit `OFFLINE` outcome becomes right; that argument was made on the issue and deferred, not lost.
- **The provider assertion is not exercised end to end.** The `mast-clone` behaviour was verified on both branches under real Windows PowerShell 5.1 (5.1.26100.9168) against a local origin, and the provider's statements were run under 5.1 with `StrictMode -Version Latest` against real sidecars carrying `fetch_ok` true, false and absent. A full `--modules mast` cycle against the dev VM covers the happy path only; the failing-fetch path through a real provisioning run has not been observed.
- **Nothing asserts the two clone scripts agree beyond the presence of `fetch_ok` in both.** That is one string per half, and the 2026-08-16 record already lists the absent `.sh`/`.ps1` equivalence as the drift alarm's weak point. This change narrows it by a millimetre.
- **The three warning surfaces are prose, not a contract.** A future edit could drop the tail warning and keep the sidecar honest; the pytest guards cover the discarded result and the field, not the operator-facing text.
