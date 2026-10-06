---
decided: 2026-10-06
status: accepted
issue: MAST_provisioning#209
areas:
  - instruments
  - unit-config
  - providers
  - drift
---

# A provider aligns the live PWI4 site, and pointing models are rebuilt rather than patched

**Why:** a read-only survey of mast01–mast08 on 2026-10-06 found three different sites in the live `PWI4.cfg`: the `sites/ns.toml` value on mast01, 06, 07 and 08, a rounded `30.053 / 35.0408055555556` on mast03, 04 and 05, and mast02's own pre-correction value. The cause is provisioning's. `sites/ns.toml` carried a wrong site from 2026-06-29 until `3fc068c` (2026-07-20), and units set up on either side of that kept what they had, because `instrument-profiles` writes the site only into the **staged** `PWI4.cfg`, which reaches the live one once, at the first `mast` logon. After that nothing re-asserted it, and nothing compared it with the site `DefaultModel.pxp` was built at. PWI4 refuses a model whose site differs from its configured one, and the mount then points on raw encoders.

**What:**

- **The control DB `sites` document is the one authority.** `sites/<site>.toml` stays its boot-time mirror, deployed as `C:\WIS\config.toml` and cross-checked by MAST_common's `_validate_local_identity` at app start. Nothing new was created; the chain is named and its last link enforced.
- **A new `pwi4-site` provider (order 1860)** aligns the live `PWI4.cfg` with `config.toml [location]`. It writes only `Latitude`, `Longitude` and `HeightMeters`, after a backup, so per-unit COM bindings and the rest of the file are untouched. It compares numerically within 1e-9 degrees (`$script:MastSiteDegreesTolerance`), because PWI4 re-rounds what it writes (`30.05301166519461` comes back as `30.0530116651946`). It refuses while `PWI4` runs, since PWI4 rewrites the file on exit. Its verify fails on a mismatch and returns exit 2 when there is no live `PWI4.cfg` yet.
- **An orphaned model is warned about, never blocked on, and never patched.** The team decision is to align every unit and rebuild every pointing model on sky (next trip, 2026-10-12 to 14), rather than refit individual models from their stored stars to save sky time. So the provider logs `POINTING MODEL ORPHANED` and the verify prints a `[WARN]`, but neither fails.
- **Not `always: true`.** A module cannot be deferred (#190), so an always-run module that refuses while PWI4 is open would fail every run made while PWI4 is up, including any automatic night-time run. Instead every `sites/*.toml` is one of the module's `repofiles`, so a site change changes its content hash and re-runs it. `test_every_site_profile_is_in_its_hash` holds that for a profile added later.
- **The drift report gets a PWI4 site section.** `tools/fleet-drift-report.py` uploads `server/lib/mast-pwi4-site-probe.ps1` with `server/lib/mast-pwi4-site.ps1` and reports, per unit, `config.toml` against the live `PWI4.cfg` against the model (`SiteVerdict`). A GUI edit, which the provider no longer catches on every run, shows there. Like the OS patch section, it does not touch the exit code.
- **The site logic lives once**, in `server/lib/mast-pwi4-site.ps1`, used by the provider, its verify and the probe.

**Rejected:**

- *Refuse to write when a model would be orphaned* (#209's first suggestion). With every model being rebuilt anyway, a refusal would only stop the alignment it exists to protect.
- *Write the model's site into `PWI4.cfg` instead.* It keeps a model loading, but leaves PWI4 disagreeing with `config.toml` and the DB, which is the inconsistency being removed.
- *Move `Set-CfgField` out of `provide-instrument-profiles.ps1` into the shared lib.* Editing `instrument-profiles` changes its hash and re-runs it fleet-wide. Its provide deletes `C:\ProgramData\MAST\instrument-profiles`, including the `.applied` sentinel, so the next `mast` logon re-copies every template `.cfg` over the live ones and re-imports the PHD2 profiles. `Set-MastPwi4CfgField` is therefore a deliberate copy until that re-run is made safe.
- *Check PWI4's site from the unit service at startup.* Filed for later as MAST_unit#296; it touches unit startup, which waits for the supervisor's unit-side work.

**Unsettled:**

- **The `instrument-profiles` re-run.** Any run that re-runs `instrument-profiles` on a deployed unit still resets its live cfgs and PHD2 profiles at the next logon. That has to be fixed before the planned full provisioning run across the fleet.
- **PWI4's own tolerance** for a model whose site differs slightly is unknown. It does not matter while every model is rebuilt at the aligned site.
