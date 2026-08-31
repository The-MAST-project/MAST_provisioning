---
decided: 2026-08-31
status: accepted
issue: MAST_provisioning#177
areas:
  - failure reporting
  - drift
  - proxy
---

# Clone currency is established against the remote, and 'unverifiable' is a third state

**Why:** `verify-mast.ps1` is the tier-2 check that exists to catch a stale checkout — its own header says a presence-only check misses *"a clone sitting on a stale commit... exactly the drift this epic exists to catch."* It established currency like this:

```powershell
${head}     = & git -C ${repoDir} rev-parse HEAD
${upstream} = & git -C ${repoDir} rev-parse '@{u}'
```

`@{u}` resolves the remote-**tracking** ref, `refs/remotes/origin/master` — a purely local pointer nothing updates but a fetch. When a fetch fails it still holds the commit `HEAD` is already on, so the two match and the clone is reported current. The check was comparing the checkout against a stale copy of the remote and reporting that agreement as currency, which means it could not see the one case it was written for.

Observed on the `#176` dev-VM run: with the unit's route to GitHub broken, `provide-mast` correctly failed all three repos and seconds later tier 2 logged `mast verify ok: 3 clone(s) current`. One root cause, two independent false greens; `#176` fixed the provider's and left this one.

Note the pre-existing `-not $upstream` branch — *"no upstream ref (never fetched?)"*. The **never**-fetched case was anticipated. The **stale**-fetch case was not, and it is the one that occurs.

**What: ask the remote, with the sidecar as fallback evidence.**

Currency now comes from `git ls-remote`. **`ls-remote`, not `fetch`**: it queries origin and updates no local ref, so the check stays read-only and one verify pass cannot alter what the next one compares against — a property worth keeping in a tool whose entire job is to observe.

When origin cannot be reached, `clone-manifest.json`'s `fetch_ok` (added by `#176`) is the only remaining evidence, and it speaks about a past moment rather than about now:

- **`fetch_ok: true`** -> `unverifiable`. The local checks passed and currency could not be established. The message names the sidecar's `written_at`, because a caveat without an age is a shrug.
- **`fetch_ok: false`, or the key absent** -> **failure**. Nothing has ever confirmed this checkout against the remote, which is the `#175` state itself. The two are worded differently — a recorded failure and a never-recorded one are different findings.
- A live answer always beats the sidecar. `fetch_ok: true` plus a remote that reports a different SHA is `stale`, not `unverifiable`; the sidecar is fallback evidence, not a veto.

**`unverifiable` is a third state, carried as verify exit 2.** `run-verify-only.ps1` records it in `status\validation.json` as `unverifiable` rather than folding it into `pass` or `fail`, and does not count it toward its own exit code — an operator's local run must not go red for a network condition. `fleet-drift-report.py` renders it apart from both and, importantly, **suppresses the all-clear `RESULT` line**: "all units in sync and bootstrap current" printed over a currency check that never completed is the same false green one level up. That report is where the fleet-wide *is everything current* question actually gets answered, so that is where the distinction has to survive.

**`execute-mast-provisioning.ps1` counts exit 2 as a success, deliberately.** Its per-module outcome is binary (`Add-MastModuleOutcome` takes a `[bool]` and feeds `fully_provisioned`), and during a provisioning run the currency question is already answered by `provide-mast`'s `fetch_ok` assertion, which has failed the module if the unit could not reach origin. Failing here as well would red-flag a module for a condition its provider either already caught or deliberately tolerated, and would have meant widening a bool through the manifest and its Pester suite to express something that surface does not need.

**No proxy configuration was added, and that is a finding rather than an omission.** The issue originally asserted that a bare `ls-remote` would fail on every on-campus run, since `verify-mast.ps1` has no proxy handling while `mast-clone.ps1` sets `HTTPS_PROXY` itself. Measured on the dev VM, `ls-remote` returns in ~1s with nothing configured at all. More importantly, `provide-proxy.ps1` sets `http_proxy` / `https_proxy` / `no_proxy` at **Machine** scope at order 100, so on a provisioned unit any later process — including an operator-launched `run-verify-only.ps1` — inherits them. That is the unit's own posture, and it is the right thing to use: imposing a different one would test a route the unit does not use. The asymmetry with `mast-clone` is intentional and has a reason — mast-clone is *also* the dev and control-host clone tool, run on arbitrary machines with no provisioned posture, whereas `verify-mast` only ever runs on a provisioned unit. This also avoids a ninth copy of the bcproxy literal, which is already in eight files (`#56` records five).

**The pinned-rev path gained a check it never had.** A detached checkout has no upstream, so `rev-parse '@{u}'` failed and the old code fell through with no comparison at all. It now asks `ls-remote --tags` for the pinned rev. Dormant today — no row in `mast-repos.tsv` pins a rev, asserted by `test_mast_clone_contract.py` — and live the moment `#75` lands one.

**The verdict table is pure and tested.** `server/lib/mast-git-currency.ps1` holds `Get-MastCurrencyVerdict` and `Get-MastVerifyExitCode` with 13 Pester cases, for the same reason `Get-MastBootstrapExitCode` is pure and tested (`2026-08-20`): a false `current` costs exactly as much operator trust as a false `stale`, and the branch that broke here was one the old inline code never made explicit. Staged unconditionally beside `mast-log.ps1` rather than as a `commandfile` of the `mast` module, because a verify-only rerun can be built from any module subset.

**Rejected:**

- **`git fetch` instead of `ls-remote`.** Simpler, and it makes verify mutate the thing it is inspecting: after one pass, `@{u}` is fresh, so the next pass's comparison is measuring the previous run rather than the remote.
- **Reading `fetch_ok` only, with no network call at all.** The cheap option, and it was the recommendation until the measurement above showed the network call is available and fast. It reports what the last provisioning run observed rather than checking, and that observation goes stale — which is the whole complaint about `@{u}`, one indirection further out.
- **Failing the run on an unreachable origin.** Symmetrical with `#176`'s disposition and wrong here for the opposite reason: `provide-mast` fails a *provisioning* run because the unit must reach a known revision to be provisioned, whereas an operator running verify on a unit with no route has a unit that is probably fine and definitely unmeasured. Red there teaches operators to ignore red.
- **Passing on an unreachable origin, as the issue first proposed.** The middle position — pass locally, report a distinct state upward — was taken instead. A pass is a pass no matter how loud the text beside it, and this epic exists because failures get reported as successes.
- **A third value through `Add-MastModuleOutcome`.** Would put `unverifiable` on the installed-manifest surface too, at the cost of widening a bool through that function, `Merge-MastInstalledManifest`, `fully_provisioned`, and their Pester coverage — to express something on a surface whose question is already answered.
- **Configuring the proxy in verify from `proxy-lib.ps1`.** See above: unnecessary, and it would override the unit's own posture.

**Unsettled:**

- **What a *campus* unit does is still unmeasured.** The dev VM reaches GitHub directly; the bench units at Neot Smadar are the case `#175` came from, and whether `ls-remote` succeeds there, needs the inherited proxy, or fails into the fallback is unknown. All three paths are exercised, but the field distribution between them is a guess. `#136` and the open reachability question from `#175` bear on the same gap.
- **The caveat reaches the fleet report as a module name, not as an age.** `validation.json` carries `unverifiable` per module; the `written_at` that makes the caveat meaningful lives only in the on-unit verify log. An operator reading the fleet report learns *that* currency is unknown, not *how long* it has been unknown.
- **Nothing asserts the exit-2 contract across the three scripts.** `verify-mast` produces it and both runners consume it, each with its own local constant; a pytest guard checks that all three states are reachable, not that the runners agree on the number.
- **`unverifiable` is only reachable from the mast module.** Every other verify script still exits 0 or 1, so the state is real but sparsely produced. `#131` is the nearest candidate for the second producer.
