---
decided: 2026-08-24
status: accepted
issue: MAST_provisioning#143
areas:
  - bootstrap
  - providers
  - drift
---

# A provisioning run re-asserts the bootstrap, every cycle

Stage 4 of MAST_provisioning#143, and the one that makes the previous three do anything on their own. The `bootstrap-reassert` provider runs `bootstrap.ps1 -ReassertOnly` on every provisioning cycle, so a unit converges on the current bootstrap during an ordinary run instead of somebody carrying a USB stick to it.

**Why every cycle rather than only when a unit is behind.** The targeted alternative — run only when the unit's stamped `bootstrap_version` is below `current_version` — is quieter and looks more disciplined. It is also useless for the case that motivated the work. A unit whose version is `null` because it predates stamping is not "behind" by that test; it is unknown, and `bootstrap_gaps()` currently hands an unstamped unit an empty missing-list. That unit is mast02, the named target of the issue. Conditional re-assert would skip precisely the machine the feature exists for.

The elements are idempotent registry writes and service checks, so the cost of running them unconditionally is log noise, not risk. **Decided by Eli:** run every time, at least for now. If the noise proves worse than the coverage, the condition can be added later — and by then the unstamped-unit hole in the drift report (stage 5) will be closed, which is what would make a conditional version safe.

**Why `execution-policy` is NOT absorbed.** The stage plan proposed folding it in, on the grounds that it is a bootstrap element already re-asserted by a provider and therefore a special case of this general mechanism. Two things say otherwise, and the second only became visible once the code existed:

- `server/prov/tests/test_execution_policy_provider.py` asserts that provider sorts **first**, because it is the precondition for every bare `powershell -File` invocation. Absorbing it would mean either breaking that invariant or making `bootstrap-reassert` itself sort first — and a provider that must run before the thing that makes it runnable is a knot with no reason to be tied.
- There is no duplication to remove. `execution-policy` is classified `reassert: provider` in the registry, so `-ReassertOnly` already skips bootstrap's copy of it. The absorption was solving a problem the classification had already solved.

So the two providers sit next to each other: `execution-policy` at order 10, `bootstrap-reassert` at 15, ahead of every provider that installs anything.

**What:**

- `server/providers/bootstrap-reassert/`, `always: true`, order 15. `provide-` runs `bootstrap.ps1 -ReassertOnly` **out of process** with a 20-minute bound, using `System.Diagnostics.Process` rather than `Start-Process` — under the WinRM host on PowerShell 5.1 the cmdlet's `-PassThru` loses the exit code of short-lived redirected processes, which is how `provide-jupyter` came to fail on successful runs. It echoes the child's summary lines into the provisioning log so a reader does not need to open a second file.
- `bootstrap.ps1` and `mast-client-util.ps1` ship as `repofiles` — the mechanism `mast-firmware.ps1` uses since MAST_provisioning#141. Both, not one: bootstrap dot-sources the util before it does anything, and shipping one without the other reaches the unit and throws a thousand lines in.
- `verify-` reads the `reassert` block out of `bootstrap-manifest.json`, fails on any failed element or a block older than 24 h (a stale block from an earlier cycle must not be read as this run's result), and writes module facts. Those reach `installed-manifest.json`, which `tools/fleet-drift-report.py` already gathers — so per-unit re-assert state arrives in the fleet view without a second gatherer, which is what stage 5 turns into a work order.
- The verify records `bootstrap_version` as a fact but never asserts on it. A re-assert applies the routine elements and by construction not the console ones, so the version must keep saying what console work is still outstanding.

**A failed element fails the module.** The re-assert is not the BIOS check: this is work provisioning owns and can retry, so a failure is a real provisioning failure rather than something to report and move past. `always: true` means that judgement applies on every cycle, which is the pressure point if an element ever turns flaky — the answer then is to fix or reclassify the element, not to soften the provider.
