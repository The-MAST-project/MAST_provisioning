---
decided: 2026-08-09
status: accepted
issue: MAST_provisioning#55
areas:
  - failure reporting
  - services
  - the operational share
---

# An unsupported nssm hook is reported absent, not worked around

**Why:** `provide-mast-shared-mount.ps1` issued `nssm set <svc> AppEvents 'Start/Pre=...'` blind and checked nothing, so on the vendored nssm build -- which has no `AppEvents` parameter at all -- it logged "Set nssm Start/Pre hook on mast-unit" and exited 0 for something that never happened. The only thing that noticed was `verify-mast-shared-mount.ps1`, and it did not report the miss either: `2>&1` captured nssm's error text, but under `ErrorActionPreference = 'Stop'` the `NativeCommandError` still terminated the script, so the operator got a stack trace instead of a verdict and the two checks after it never ran.

Found on mast01's first real-unit run during the fleet migration (2026-08-06), and confirmed on every unit: `installed-manifest.json` recorded `mast-shared-mount` as `provide: pass` / `verify: fail`, which was the sole reason `fully_provisioned` stayed false fleet-wide on otherwise fully migrated units.

The hook was not decoration. It existed to close the boot race on the operational `Z:` mapping that the at-startup SYSTEM task does not cover -- a `mast-unit` restart *without* a reboot, after which `Filer` was understood to fall back silently to `C:\MAST`. That fallback is the failure behind the frames lost on 2026-07-14.

**What:** the provider probes for support (`nssm get <svc> AppEvents 'Start/Pre'`) before attempting the set, checks `$LASTEXITCODE` on the set itself, and on an unsupported build logs plainly that the hook is not set and names what remains uncovered. The verify isolates the same probe behind a local `ErrorActionPreference = 'Continue'` and a `try/catch/finally`, treats "no `AppEvents` on this build" as a reported condition rather than a failure, and continues to its remaining checks. Neither script now claims the hook exists.

The module therefore records clean on a build that cannot carry the hook, and `fully_provisioned` becomes reachable again.

**Rejected:**

- *Vendoring a newer nssm that has `AppEvents`, and upgrading it across the fleet* -- a new binary asset with the retention and provenance questions #48 exists to answer, plus a service-manager swap on four production units, to close a window that upstream work removes anyway (see below).
- *Building a different durable mechanism* -- a scheduled task triggered on service start, or a per-start check inside the service's own startup path. Same objection: a new load-bearing mechanism for a problem scheduled to stop existing.
- *Keeping the module in a failed state until the hook can genuinely be set* -- honest, but it holds `fully_provisioned` false fleet-wide, which is the gate on the #41 deletions and on any future fleet-wide "is everything current" question. The failure signal would be permanently on, which makes it worth nothing.

**Unsettled:**

- **The residual window is real and is not closed by this change.** A `mast-unit` restart without a reboot still has nothing re-establishing the mapping in the LocalSystem session. It was judged acceptable because MAST_common#26 -- deriving the shared root from `controller_host` as a UNC path rather than a drive letter -- removes the dependency entirely, and its own acceptance criteria state that `mast-shared-mount` then becomes belt-and-braces rather than load-bearing. That issue is open, so the judgment rests on work not yet done. If #26 stalls, this decision should be revisited rather than left standing.
- The `Invalid parameter` string match is how an unsupported build is recognized, alongside a non-zero exit. That is nssm's current wording and nothing pins it.
- Which nssm build the fleet actually carries, and whether any unit differs, was not inventoried -- the probe makes the provider correct on either kind of build, so it was not needed to land this, but "the fleet is uniform" remains an assumption.

**Implications:** the pattern here is the one #38 is about at a larger scale -- a provider whose exit code does not reflect what it achieved. This fixes one instance by checking the result of a native call; #38 is the general case where a `throw` never reaches the orchestrator at all. Whoever takes #38 should expect more of these, and the probe-then-act shape is a reasonable template.
