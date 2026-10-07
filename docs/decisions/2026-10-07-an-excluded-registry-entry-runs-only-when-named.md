---
decided: 2026-10-07
status: accepted
areas:
  - unit-config
  - providers
---

# An excluded registry entry runs only when named

**Why:** `server/unit-registry.json` lists mast00 and mastw beside the production units, so a plain `check_and_provision.py` run provisions them too. Neither should be in a fleet run. mast00 is the development unit and was never production-provisioned: the 2026-10-07 dry run had all 47 modules missing on it, and `pwi4-site` would have rewritten its PWI4 site to its `config.toml` value and orphaned its pointing model. mastw is the Weizmann site unit: it has no `config.toml` and cannot open SMB to the provisioning server's staging share. Keeping them out depended on every operator remembering `--only-hosts mast01,...,mast08`.

**What:** `UnitEntry` gains an optional `excluded` field that holds a non-empty reason. `registry.select_units(units, only_hosts)` decides what a run provisions. With `--only-hosts`, it is exactly the named units, excluded or not. Without it, it is every unit but the excluded ones, and the driver logs `UNIT_EXCLUDED` with the reason for each one left out. mast00 and mastw carry a reason in the registry.

**Implications:**

- A one-off run on an excluded unit is still possible, and has to be deliberate: name it.
- `select_units` is the only place the driver picks units, so the rule cannot diverge between paths. The `--loop` service runs the same selection.
- Read-only tools are not affected. `fleet-drift-report.py` still reads every registry hostname, so excluded units stay visible in reports.

**Rejected:**

- *Remove the two entries from the registry.* The registry is also the record of the fleet, and the drift report and the inventory phase's MAC write both read it.
- *A boolean flag.* A reason says, in the file, why a unit is left out.
- *An empty maintenance window.* It hides the intent behind scheduling, and a `--force` or a window override would still reach the unit.
