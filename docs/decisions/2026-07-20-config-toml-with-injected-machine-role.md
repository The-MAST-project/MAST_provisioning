---
decided: 2026-07-20
status: accepted
issue: MAST_common#15
areas:
  - unit-config
  - bootstrap
  - providers
---

# The bootstrap file is `C:\WIS\config.toml` with an injected `machine_role`, and `MAST_PROJECT` is gone

Supersedes the design in the archived 2026-06-29 `config-bootstrap` entry
(`C:\WIS\unit.toml` selected by the `MAST_PROJECT` environment variable), which is in
`archive-2026-05-04-to-2026-08-03.md`.

**Why:** MAST_common epic (The-MAST-project/MAST_common#15) removes the `MAST_PROJECT`
environment variable. The apps now read a single fixed-path bootstrap file whose role is a
required in-file `machine_role` field, instead of a role-named file selected by an env var.
Provisioning was the writer of that file (and a machine-wide env-var setter), so it has to
change in lockstep or units fail startup on the new `common`.

**What:** `config-bootstrap/provide-config-bootstrap.ps1` now writes the fixed path
`C:\WIS\config.toml` (was `C:\WIS\<role>.toml`) and **injects `machine_role = "<Role>"`** as a
top-level key prepended ahead of the site-profile body (it must precede the `[location]`
table); the machine-wide `MAST_PROJECT` set is removed. `verify-config-bootstrap.ps1` now
asserts the in-file `machine_role` value instead of the env var. The NSSM service
(`provide-mast.ps1`) and the mast-validation harness
(`provide-mast-validation.ps1` / `validate_mastrometry.py`) no longer set `MAST_PROJECT`.
The `instrument-profiles` provider -- a **second reader** of the bootstrap file -- was updated
to read `C:\WIS\config.toml [location]` (previously `unit.toml`); this reader was not listed
in the epic's provisioning stage but the filename change breaks it otherwise. Docs
(`README.md`, `CLAUDE.md`, the `sites/*.toml` header comments, `build-mast.ps1` comments)
updated to the new path/field. The per-site profiles stay role-agnostic -- role is injected at
provision time.

**Rejected:**

- **Baking the role into each site profile** rather than injecting it at provision time.
  Rejected to keep `sites/*.toml` role-agnostic: a site profile describes a place, and one
  place can host machines in different roles. Injection keeps the profile reusable and puts
  the role where provisioning already knows it.
- **Keeping `MAST_PROJECT` set alongside the new field**, as a transition aid. Rejected --
  two sources for the same fact is exactly what the epic removes, and a stale env var
  disagreeing with the file is a failure mode that only exists if the var survives.
- **A migration that rewrites existing `C:\WIS\<role>.toml` files in place** on units. Not
  taken: a unit on the new `common` with an old file fails fast at startup, which is the
  intended breaking behavior, and units are fixed on the next provision anyway. A migration
  path would add code whose only purpose is to soften a break that should be loud.
- **Appending `machine_role` at the end of the file.** Not viable rather than rejected on
  taste -- it is a top-level key and TOML puts every top-level key before the first table,
  so it must precede `[location]`.

**Unsettled:**

- **Not exercised on a VM or a unit.** The provisioning verification is deferred to epic
  #15, so at the time of the decision this is a correct-by-reading change only.
- **Whether `instrument-profiles` is the last reader.** It was found by inspection after the
  epic's provisioning stage failed to list it, which means the enumeration of readers is
  known to have been incomplete once. Another unlisted reader would break the same way.
- **The break is deliberate and its blast radius is a belief.** Every unit not yet
  reprovisioned fails at startup once the new `common` reaches it; the sequencing of those
  two events across the fleet was not planned in this change.
- **Landed on `eli/machine-role`, branched off and targeting `eli/provisioning-v3`**, so it
  reaches `main` only when the v3 branch does.

**Implications:** A unit on the new `common` with an old `C:\WIS\<role>.toml` (or a
`config.toml` lacking `machine_role`) fails fast at startup, by design; units are fixed on the
next provision.
