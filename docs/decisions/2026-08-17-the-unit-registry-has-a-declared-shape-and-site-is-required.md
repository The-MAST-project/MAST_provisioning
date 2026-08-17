---
decided: 2026-08-17
status: proposed
issue: MAST_provisioning#87
areas:
  - unit-config
  - static analysis
  - failure reporting
---

# The unit registry is a pydantic model, and `site` is required

**Why:** `server/unit-registry.json` is the driver's most-read data structure and it was `dict[str, Any]` end to end. `unit["hostname"]`, `unit.get("modules")`, `unit["mac"]` -- none of it verifiable, no way to tell a required key from an optional one, and a typo or a renamed field surfaced as a `KeyError` mid-run against a real unit. Stage 3 of #87.

**What:** a new module `server/prov/registry.py` owning `UnitEntry` and `MaintenanceWindow` (pydantic `BaseModel`), `load_unit_registry()` and `dump_unit_registry()`. The driver's five `unit:` parameters and both registry reads take the model; `prov.maintenance_window` takes a window instead of a whole unit.

The shape comes from the six live entries on the prov server plus the template, not from invention: `hostname`, `site`, `timezone`, `maintenance_window` on 6 of 6; `mac` on 4 (and *written back* by the inventory phase); `ip` on 3; `modules` on none, being the deliberate opt-in that restricts a unit to a subset of providers. Plus `_comment`, which the template carries.

**Pydantic, not a TypedDict.** This landed first as a `TypedDict` and was rewritten during review, which is worth recording because the arguments that changed the answer are not obvious. Three things decided it:

- **The fleet already models config this way.** MAST_common's entire config layer is `BaseModel` -- `UnitConfig`, `RoiConfig`, `LocalConfig`. The unit registry is config. A `TypedDict` here would have made this repo the one place in MAST where a config document is a bare dict, against both the fleet's practice and this repo's own Python conventions.
- **Validation stops being hand-rolled.** The TypedDict version validated three things in bespoke code and left the rest -- `ip`, `mac`, `modules` types, and every nested field bar the window -- on trust. Pydantic checks all of them, reports every problem in one error with field paths, and nests `MaintenanceWindow` for free.
- **The runtime-introspection wart disappears.** `prov.transport` uses `from __future__ import annotations`, so its annotations are strings, `TypedDict` cannot resolve `NotRequired`, and `UnitEntry.__required_keys__` reported *every* key -- a test had to hard-code the required set and explain why. `model_fields[...].is_required()` just works, so the test derives it.

**Closed models, not `extra="allow"`.** Every key the file may carry is declared, `_comment` included (aliased, since pydantic treats a leading underscore as a private attribute). Two things follow. A round-trip cannot silently drop a field -- which matters because the inventory phase rewrites the **whole file** to record one MAC, so a lossy dump would quietly edit the operator's registry. And `extra="forbid"` turns a misspelled key into an error at the read: `sitte: "ns"` would otherwise be carried along forever while `site` went missing. `dump_unit_registry` uses `by_alias=True, exclude_none=True` so a key the file did not carry does not come back as an explicit `null` -- this file is hand-edited and a MAC write must not reformat every other entry. Both directions are pinned by tests.

**`site` is required, which reverses a recorded decision.** The `2026-06-29` entry in `archive-2026-05-04-to-2026-08-03.md` ("Interactive bootstrap: operator picks the site, carried via the unit registry") chose the opposite: *"A registry entry with no `site` logs `SITE_MISSING` and falls to build-mast's default (`wis`) -- backward-compatible with existing dev entries, but loud, so a production unit can't silently take the dev profile."* That was right while dev entries predating the field existed. They no longer do -- all six entries on the prov server carry a site, checked before this landed -- so the fallback now only covers a mistake, and a unit provisioned against the wrong site's `.toml` is not something a log line makes safe. The `SITE_MISSING` event goes with the branch that emitted it.

**`in_maintenance_window` takes a window, not a unit.** Its eight tests all passed bare dicts (`{}`, `{"timezone": ...}`), none of them valid registry entries. Requiring a `UnitEntry` would have made every window test invent a hostname and a site to say nothing about windows, so the signature narrowed to `(window, timezone)` instead and the function stopped caring what a unit is. Its `window_fields_missing` branch is gone with it: `MaintenanceWindow` requires both bounds, so a half-specified window is rejected at the read and the runtime case became unreachable. That test moved to the loader's rejection cases.

**Two subscripts of optional keys fell out of the retype**, which was the object of the exercise: `_resolve_modules` reached `unit["modules"]` behind an `if unit.get("modules")`, and `_build` read `unit["site"]` behind a guard that the required field makes unnecessary.

**Rejected:**

- **A `TypedDict`**, as above -- built, then replaced.
- **`extra="allow"` plus preserving extras on dump**, which was the first answer to the round-trip risk. Modeling `_comment` is strictly better: it needs no extras machinery, and it makes a misspelled key an error rather than a value silently carried.
- **A bare `cast` at the JSON boundary**, which is what a TypedDict needs to bridge from `dict[str, Any]`. It tells the checker a shape holds without establishing it -- the pattern behind the failure found the same day, where `unit/src/solvers/mastrometry.py` casts a `RoisConfig` member to `SpecRoiConfig` and reads `fiber_x` off it, so a plain `RoiConfig` in the config produced an `AttributeError` in the middle of an end-to-end plate solve three weeks after the models diverged.
- **A frozen dataclass.** Cheaper than pydantic and no new dependency, but it hand-rolls the validation and the JSON round-trip that pydantic gives, for a document that is read and written as JSON.
- **Putting the models in `prov.transport`** beside the JSON readers, where they started. Transport is the WinRM/SSH layer; a config schema is not transport, and `prov.maintenance_window` would then import the transport module to type an hours pair.
- **Making `timezone` required too.** `in_maintenance_window` already degrades to server-local time with a `MAINT_TZ_WARN`, which is benign in a way a wrong site is not.
- **`in_maintenance_window(unit: UnitEntry)`**, keeping the wider signature. Above.

**Unsettled:**

- **Pydantic is a new runtime dependency for the provisioning server.** Declared in `server/requirements.txt`, and `pip install --dry-run` on the prov server resolves `pydantic-2.13.4-py3-none-any.whl` plus a `cp312-win_amd64` `pydantic_core` wheel, so there is no build step -- but it is the first substantial dependency this server has taken, in a repo that otherwise vendors and installs offline, and **it is not installed on the prov server yet**. Whoever deploys this runs `pip install -r server/requirements.txt` first or the driver will not import.
- **Nothing validates the registry ahead of a run.** The read rejects a bad entry at driver start -- early, but still after `RUN_START`, so an operator editing the registry finds out on the next cycle rather than at edit time.
- **One bad entry rejects the whole file.** Correct for a fleet loop that would otherwise provision an unknown site; it does mean one typo stops every unit.
- **The template/model contract test compares key names**, so a `maintenance_window` written as a string in the template passes that check and fails only at the load assertion below it.
- **`tools/fleet-drift-report.py` keeps its own `UnitRecord`**, built from units' installed manifests. That is a different thing -- observed state, not declared config -- so it is probably right that they are separate, but nothing says so.
