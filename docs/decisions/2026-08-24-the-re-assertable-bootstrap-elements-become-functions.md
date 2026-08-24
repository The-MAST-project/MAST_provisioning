---
decided: 2026-08-24
status: accepted
issue: MAST_provisioning#143
areas:
  - bootstrap
  - drift
  - static analysis
---

# The re-assertable bootstrap elements become functions, and the registry is held to them

Stage 2 of MAST_provisioning#143. Ten of the nineteen bootstrap elements are now functions addressed by id through `$script:MastBootstrapElementActions`; the main flow calls them instead of holding their code inline. Nothing re-runs anything yet — but the code a re-assert run will call now exists in a form that can be called, and the build now checks that the registry and the script agree about what that set is.

**Why only ten.** The obvious reading of "extract the elements" is all nineteen. That is the wrong scope, and not for effort reasons: the set that must be individually invocable is exactly the set a re-assert run may invoke. `routine` and `on-demand` elements qualify. `console` elements must be the opposite of invocable — reaching `computer-rename` or `mast-admin-account` remotely is the failure the classification exists to prevent, so making them dispatchable would add the hazard while adding no capability. `provider` elements are re-asserted by a provider, not by re-running bootstrap's copy. Extracting those nine would have meant a much larger diff through the most dangerous code in the script (account creation, rename, the interactive Npcap installer) to produce entry points nothing may use.

So the guard is scoped the same way, and states the invariant in both directions: every `routine` or `on-demand` element **must** be dispatchable, and nothing else **may** be. That is a complete check over the set that matters, not a partial check over all of them.

**Why functions and not scriptblocks in the map.** The first cut put each element's body in a hashtable of scriptblocks, `'id' = { ... }`. It parses, but every element body is indented four spaces because it came from inside a `try` block, so an inner `}` closing a nested `try` is indistinguishable from the `    }` closing the entry. A verifier reading it line-by-line silently truncated bodies at the first inner brace, and a human reading the diff has the same problem. Functions close at column 0, which no line inside a body can, so the boundaries are unambiguous to a reader, to a regex, and to the parser. They are also individually greppable and callable, which the later stages want anyway.

**How "movement only" is known rather than claimed.** The extraction was done by line range, and then verified by reconstructing the original: strip the added block, expand each `Invoke-MastBootstrapElement -Id 'x'` call back into the body of its function, and diff against the pre-change file. **1887 lines in, 1887 lines out, byte-for-byte identical.** A refactor of first-touch code that only fully exercises on bare hardware needs a stronger claim than "I was careful", and this is one that can be re-run by anyone.

Two dependency audits back it up, because moving code into a function changes what it can see:

- **Reads.** No element reads a variable defined earlier in the main flow. All ten touch only script parameters, `$script:` state, functions, and their own locals — so dynamic scoping delivers exactly what they had inline.
- **Writes.** No element writes a variable the later main flow reads. Three candidates surfaced and all three were false positives: `$null =` is the discard idiom, and `$s` / `$t` are scratch locals independently bound at each site — the Verification section has its own `foreach ($t in $script:TrimList)`.

**What:**

- Ten functions, `Invoke-MastBootstrapElement<Id>`, holding the moved bodies; `$script:MastBootstrapElementActions` maps id → function name; `Invoke-MastBootstrapElement -Id` dispatches and throws on an unknown id.
- `Test-MastBootstrapDispatchCoverage` in `build/build-bootstrap-lib.ps1`, called by `Assert-MastBootstrapElementRegistry`: every re-assertable element is dispatched, nothing else is, and every mapped function is actually defined. **This is the check the registry never had** — its `id` was a label the drift report printed, matched against nothing, which is how three sections of the script came to have no element at all.
- The build line now reports the dispatchable count alongside the classification counts.

**Not yet verified, and it is the gate before merge.** A full VM bootstrap cycle (`vm/run-prov-test.py`). Everything above is static: the parse is clean on PowerShell 5.1, the movement is proven, the guard passes both ways, 24 Pester tests and the PSScriptAnalyzer sweep are green over 129 files. What none of that exercises is bootstrap actually running end to end — and several extracted elements behave differently on real hardware than in a VM (the Intel I225 NIC paths, the Npcap installer next door). A green VM cycle is necessary and still not sufficient; the first real use should be a unit someone is standing next to.
