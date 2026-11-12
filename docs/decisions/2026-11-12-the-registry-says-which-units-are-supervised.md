---
decided: 2026-11-12
status: accepted
issue: MAST_provisioning#82
areas:
  - unit-config
  - services
  - dev-harness
---

# The registry says which units are supervised

**Why:** the supervisor's Windows service, `mast-service`, is to be installed one unit at a time (team decision, 2026-11-04), so provisioning needs a per-unit declaration of which units get it. The existing per-unit `modules` list cannot be that declaration: leaving a module out never uninstalls it, so a unit taken off supervision would keep a running service.

**What:**

- `UnitEntry` gains an optional `supervised` field. It is `StrictBool | None` with a default of `None`, not `bool = False`: `dump_unit_registry` drops only `None`, so a `False` default would be written into every entry at the next MAC write. Strict, so a hand-written `"yes"` or `1` is rejected at the read rather than taken as true.
- The driver passes `-Supervised` to `build-mast.ps1` only for an entry with `supervised: true`.
- `build-mast.ps1` takes it as a switch and bakes it into the `mast-service` module's command, the channel `-Site` and `-DirectHttp` already use. The command folds into that module's content hash, so flipping the flag changes the hash and drift re-runs the module.
- `vm/run-prov-test.py --supervised` builds the dev VM the same way, since the VM has no registry entry.

**Implications:**

- The flag is inert until the `mast-service` provider exists: no module is named `mast-service` yet, so the build's switch case never matches, and no registry entry sets the flag (a test pins that).
- A unit reads as unsupervised whether the key is absent or `false`. Only `true` passes the switch.

**Rejected:**

- *The `modules` list.* Leaving a module out does not remove what it installed.
- *A `bool = False` field.* It rewrites every hand-edited entry on the next MAC write.
