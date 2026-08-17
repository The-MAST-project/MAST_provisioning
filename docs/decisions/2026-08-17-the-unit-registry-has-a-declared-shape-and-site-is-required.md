---
decided: 2026-08-17
status: proposed
issue: MAST_provisioning#87
areas:
  - unit-config
  - static analysis
  - failure reporting
---

# The unit registry has a declared shape, and `site` is required

**Why:** `server/unit-registry.json` is the driver's most-read data structure and it was `dict[str, Any]` end to end. Every access -- `unit["hostname"]`, `unit.get("modules")`, `unit["mac"]` -- was unverifiable, so a key typo or a renamed field would surface as a `KeyError` mid-run against a real unit, and nothing could tell an optional key from a required one. Stage 3 of #87.

**What:** `transport.UnitEntry` (a `TypedDict`) plus `transport.MaintenanceWindow`, and `transport.load_unit_registry()` which validates before returning them. The driver's five `unit: dict` parameters and both registry reads now name those types.

```python
class UnitEntry(TypedDict):
    hostname: str
    site: str
    timezone: NotRequired[str]
    maintenance_window: NotRequired[MaintenanceWindow]
    ip: NotRequired[str]
    mac: NotRequired[str]
    modules: NotRequired[list[str]]
```

The shape is taken from the six live entries on the prov server plus the template, not invented: `hostname`, `site`, `timezone` and `maintenance_window` appear on 6 of 6, `mac` on 4 (and is *written* back by the inventory phase), `ip` on 3, and `modules` on none -- it is the deliberate opt-in that restricts a unit to a subset of providers.

**`site` is required, which reverses a recorded decision.** The `2026-06-29` entry in `archive-2026-05-04-to-2026-08-03.md` ("Interactive bootstrap: operator picks the site, carried via the unit registry") chose the opposite: *"A registry entry with no `site` logs `SITE_MISSING` and falls to build-mast's default (`wis`) -- backward-compatible with existing dev entries, but loud, so a production unit can't silently take the dev profile."* That was the right call while dev entries predating the field still existed. They no longer do -- all six entries on the prov server carry a site, checked before this landed -- so the fallback now only protects against a mistake. A unit taking the wrong bootstrap config profile is not a defect a log line makes safe, and `SITE_MISSING` was the last thing standing between a typo'd registry and a unit provisioned against the wrong site's `.toml`. The event is gone with the branch that emitted it, and the loader rejects the entry instead.

**Validation, not a bare `cast`.** `load_json_list` returns `dict[str, Any]`, so something has to bridge to `UnitEntry`; the cheap option is a `cast` at the boundary. That is exactly the pattern that produced the failure found the same day this was written -- `unit/src/solvers/mastrometry.py` casts a `RoisConfig` member to `SpecRoiConfig` and reads `fiber_x` off it, and when the config held a plain `RoiConfig` the checker had been told to look away, so an `AttributeError` landed in the middle of an end-to-end plate solve three weeks after the models diverged. So `load_unit_registry` checks that `hostname` and `site` are non-empty strings and that `maintenance_window`, if present, carries two integer hours, raising `TypeError` naming the file and the offending entry, and only then casts. Same contract as `load_json_object` / `load_json_list`.

**Two subscripts of optional keys came out of the retype**, which was the point: `_resolve_modules` did `if unit.get("modules"): return list(unit["modules"])` (now bound to a local, since `.get()` truthiness does not narrow a TypedDict key) and `_build` read `unit["site"]` behind an `if unit.get("site")` guard (now a plain read, per the decision above).

**Rejected:**

- **A frozen dataclass or a pydantic model** instead of a `TypedDict`, which is what this repo's Python conventions ask for at module interfaces. Rejected on the round-trip: the registry *is* a JSON document, the inventory phase mutates an entry in place (`u["mac"] = mac`) and rewrites the whole list with `write_status_atomic`, so a non-dict model buys a (de)serialization layer for no additional safety here. pydantic would also be a new runtime dependency for the provisioning server, which currently has none of it (MAST_common's use of it does not reach this repo).
- **`cast` at the boundary with no checks.** Cheaper, and covered above.
- **Making `timezone` required too.** It is on 6 of 6 entries and `in_maintenance_window` falls back to server-local time with a `MAINT_TZ_WARN` when it is absent -- a documented, benign degradation, unlike a wrong site.
- **Validating the optional string keys' types.** `ip` and `mac` are read for logging and for the SMB preflight, where a malformed value fails visibly at the point of use. Checking them would mean deciding what a valid MAC or address *is*, which is a bigger commitment than this change needs.
- **Deriving the test's required-key set from `UnitEntry.__required_keys__`.** It does not work here and the reason is worth knowing: `prov.transport` uses `from __future__ import annotations`, so its annotations are strings, `TypedDict` cannot resolve `NotRequired` at runtime, and `__required_keys__` reports *every* key. pyright reads the source and gets it right, which is what gates the code. The test spells the two required keys out and says why.

**Unsettled:**

- **Nothing validates the registry ahead of a run.** The loader rejects a bad entry when the driver starts, which is early but still after `RUN_START`; an operator editing the registry finds out on the next cycle rather than at edit time. A `--check-registry` flag or a pre-commit hook on the prov server would close that.
- **`load_unit_registry` rejects the whole file for one bad entry.** Correct for a fleet loop that would otherwise provision an unknown site, but it means one typo stops every unit rather than skipping one.
- **The `UnitEntry` / template contract test compares key *names*, not types.** A `maintenance_window` written as a string in the template would pass the key check and fail only at the load assertion below it.
- **`tools/fleet-drift-report.py` builds its own `UnitRecord`** from the units' installed manifests and does not use `UnitEntry`. The two describe different things (expected config vs observed state), so this is probably right, but nothing states the relationship.
