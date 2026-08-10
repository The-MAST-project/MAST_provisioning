---
decided: 2026-08-09
status: accepted
issue: MAST_provisioning#41
areas:
  - unit-config
  - fleet migration
  - providers
---

# The machine_role migration is complete, and its retirement code is removed

**Why:** `config-bootstrap` is a permanent provider that was also carrying one-time code: it deleted the legacy role-named `C:\WIS\<role>.toml` and unset the machine-wide `MAST_PROJECT`. That was correct while units still had them. All four production units were migrated by 2026-08-09 and verified carrying `C:\WIS\config.toml` with `machine_role`, neither legacy form present, so the code now runs on every cycle to do nothing.

One-time machinery left in a permanent provider stops looking one-time. This one deletes a config file and unsets a machine-wide environment variable on every run of every unit forever, which is a standing hazard in exchange for no remaining benefit.

**What:** the retirement block is removed from `provide-config-bootstrap.ps1`. The provider now only writes `config.toml`.

`verify-config-bootstrap.ps1`'s two assertions -- no legacy role-named file, no machine-wide `MAST_PROJECT` -- are **kept**, which #41 asked to be decided explicitly rather than swept along with the deletion. They are two `Test-Path`-grade checks, and what they defend against is a unit acquiring a second, contradicting source of its own identity. Their comment now says they are a regression guard rather than a migration check, and that nothing repairs them any more: a failure is a report, not a self-healing step.

The description in `module.json` already stated the current position ("There is no MAST_PROJECT environment variable") rather than the transition, so it needed no edit.

**Rejected:**

- *Deleting the verify assertions too, for symmetry.* The provider's removal code and the verify's detection code look like a matched pair but are not: one is migration, the other is invariant. Deleting both would leave nothing noticing if `MAST_PROJECT` came back -- via a hand-run script, a restored image, or a future provider written by someone who remembers the old scheme.
- *Keeping the retirement block "just in case" a stray unit turns up.* An unmigrated unit fails `verify-config-bootstrap` loudly and is then migrated deliberately, which is better than a permanent provider silently repairing it. mast00 and mastw are non-production and out of the fleet gate.

**Unsettled:**

- The assertions are scoped to the run's `-Role`, so `C:\WIS\<other-role>.toml` would not be noticed. Only `unit` exists today; a second role would want this revisited.
- mast03 still carries a `C:\WIS\unit.toml.bak` from hand work on 2026-07-08. It does not match the assertion and nothing removes it. Harmless, and left alone rather than quietly deleted by a provider.

**Implications:** `config-bootstrap` is now a purely permanent provider. This is one of the two one-time migrations #41 tracks; the other is the `C:\MAST\src` layout.
