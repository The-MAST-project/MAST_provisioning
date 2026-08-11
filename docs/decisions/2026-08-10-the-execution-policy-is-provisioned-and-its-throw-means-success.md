---
decided: 2026-08-10
status: accepted
issue: MAST_provisioning#51
areas:
  - bootstrap
  - providers
  - failure reporting
---

# The ExecutionPolicy is provisioned, and Set-ExecutionPolicy throwing means it worked

**Why:** `bootstrap-winrm.ps1` only **printed** the instruction —

```
MANUAL STEP: Set-ExecutionPolicy RemoteSigned -Scope LocalMachine
```

— and the step was duly skipped on mast04 (2026-07-07) and mast03 (2026-07-08), then applied by hand both times. A printed instruction is not a mechanism.

It stayed skipped for days because nothing notices. Every provisioning invocation passes `-ExecutionPolicy Bypass`, so a Restricted unit provisions perfectly and breaks only for whatever later runs a bare `powershell -File`. The 2026-07-12 SSH-first record listed that masking as an open question and left it open.

The belief going in was that the step was manual because the setting could not be automated. Measured on mast03 (PS 5.1.19041.4522), that is false in an interesting way. SSH sessions come up elevated (`elevated=True`), and a `.ps1` invoked exactly as a provider is *does* set the policy and persist it to `HKLM`. But:

```
--- setting LocalMachine -> RemoteSigned (registry now: Bypass) ---
  THREW: Security error.
  type:  System.Security.SecurityException
  fqid:  ExecutionPolicyOverride,Microsoft.PowerShell.Commands.SetExecutionPolicyCommand
  registry after = RemoteSigned          <-- the write landed
```

`Set-ExecutionPolicy` writes the registry and *then* throws, whenever a more permissive policy in a higher-precedence scope shadows the scope just written. Our own `-ExecutionPolicy Bypass` wrapper puts `Process=Bypass` in precisely that position, so **setting LocalMachine to RemoteSigned throws every single time it succeeds.** Under `ErrorActionPreference = 'Stop'` the naive form aborts mid-script: a comparison run confirmed execution never reached the line after the call, and an unhandled terminating error exits 1.

That is also why the step looked like something only a human could do. Run interactively, `Process` is `Undefined`, nothing shadows the write, and no exception is raised — the automated path is the only one that throws.

**What:** a new `execution-policy` provider, order **10** (before `timesync` at 50), `always: true`.

The provider takes its verdict from **reading the policy back**, never from the absence of an exception. It catches `SecurityException` and treats `FullyQualifiedErrorId -like 'ExecutionPolicyOverride*'` as the expected outcome of a successful tighten, logging why; any other `SecurityException`, and any other exception, is logged as itself. Then it re-reads `LocalMachine` and that read alone decides pass or fail.

`verify-execution-policy.ps1` re-reads the **live** policy rather than trusting the smoke marker, and additionally fails when `MachinePolicy` or `UserPolicy` is defined. A GPO scope outranks `LocalMachine`, so `Set-ExecutionPolicy` can succeed, the persisted value can read correct, and the effective policy can still be Restricted — a unit reported healthy that cannot run a bare `powershell -File`. The full scope table goes to the log either way, so a domain-policy change is diagnosable instead of mysterious.

`bootstrap-winrm.ps1` now sets the policy itself (`Set-MastExecutionPolicy`, same override handling, warnings instead of exit codes) and the manual-step block is gone. Bootstrap version 9, with a matching `bootstrap-elements.json` element.

Validated on mast03: the skip path (already RemoteSigned), the set path with the override throw live (`Bypass` → `RemoteSigned`, exit 0), verify passing, and verify failing on out-of-band drift while the smoke marker still read clean.

**Rejected:**

- *Fixing only the bootstrap (part 1 of #51).* It is a one-shot an operator can skip, which is what already happened twice. The provider is the part that makes the setting durable; bootstrap is the part that stops a fresh unit shipping Restricted in the meantime. Both, not either.
- *Dropping the `-ExecutionPolicy Bypass` wrapper* — the question the 2026-07-12 record left open. **Keep it.** Bootstrap has to work on a unit whose policy has not been set yet, so removing it creates a chicken-and-egg for the very step that fixes the problem. The masking it causes is now addressed where it belongs: by a verify that asserts the real state, not by making every invocation fragile. A second reason emerged from the measurement — the wrapper is what produces `ExecutionPolicyOverride`, and that throw is now a signal the provider reads deliberately.
- *`always: false`, relying on drift detection.* Drift is payload-hash-based. A policy changed out of band leaves the module hash untouched, so no drift is raised and the verify never runs — blind to exactly the condition the provider exists to catch. This is the first `always` module at the *head* of the order rather than an order-terminal one (`proxy` 100, `mast-services-finalize` 9500, `reboot` 9999), which widens what `always` means: not only "cross-cutting step that must close out a run" but also "asserts machine state that nothing else would re-check." Cost is about a second per cycle.
- *Setting `Bypass` instead of `RemoteSigned`.* It would work and is strictly weaker. `RemoteSigned` runs local unsigned scripts — which is every provider file — while still requiring a signature on anything downloaded.
- *Asserting only `LocalMachine` in verify.* Cheaper, and wrong in the one case that matters: it reports success on a GPO-overridden unit.

**Unsettled:**

- **No unit has ever been provisioned by this provider.** All four are already `RemoteSigned`, applied by hand, so its first production run will be a no-op skip on every existing unit. The set path is validated only by a deliberately planted `Bypass` on mast03; the first real exercise is the next new unit.
- **The GPO branch is untested.** All GPO scopes read `Undefined` fleet-wide, so the failure path for a domain-defined policy is reasoned, not observed. It is also the one failure this provider can only report, never fix.
- **`bootstrap-elements.json` had drifted to `current_version: 1` while the constant read 8** — elements for versions 2 through 8 were never recorded, so `fleet-drift-report.py` has been emitting its bump-them-together warning. Both are now 9 and consistent, but the missing history for 2–8 was not reconstructed: attributing seven capabilities to versions after the fact would be invention, and the report's per-unit "may need applying" list stays incomplete for them.
- **Whether the bootstrap's version bump should be automatic.** Two files plus a constant have to move together, which is what let them drift in the first place.
