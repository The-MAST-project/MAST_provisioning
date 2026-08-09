---
decided: 2026-08-03
status: accepted
issue: MAST_provisioning#25
areas:
  - drive letters
  - the operational share
  - service logon sessions
  - credentials
---

# `Z:` belongs to the operational share, and must be mapped in the SYSTEM session

**Why:** `client/execute-mast-provisioning.ps1` mapped `Z: -> \\<ProvServer>\mast-shared`
persistently at execute start, and `server/setup-smb-share.ps1` printed that as the
contract. On a production unit `Z:` is not ours to claim: MAST_common's `Filer` roots
its "shared" area on `Z:\MAST\<hostname>\` and the ram-to-shared mover writes every
exposure there, so the letter has to mean the site controller's share
(`\\<controller_host>\mast-share`, i.e. `/Storage/mast-share`). Because the old code
skipped when the letter was already taken, which host owned it was order-dependent, and
the fleet drifted: on 2026-08-02 mast00's `Z:` pointed at the pre-rename
`\\mast-wis-control\mast-share` and mast03's at the provisioning laptop's `mast-shared`,
both reading *Unavailable*.

The mapping was also in the wrong **session**, which is the part the original issue
write-up missed. The MAST services are installed by nssm with no `ObjectName`, so
`mast-unit`, `mast-phd2`, `mast-pwi4` and `mast-pwshutter` were understood to run as
**LocalSystem** (confirmed on mast03). Windows drive letters are per-logon-session.
Execute runs as the autologon `mast` user, so even a *correct* mapping it made would be
invisible to the process that calls `Filer` -- and `Filer.__init__` silently substitutes
`C:\MAST` when the `Z:` probe fails. That silent substitution is what made the
2026-07-14 mast03 tracking-test exposures look lost: they were on `C:` all along.

**What:**

- **Execute maps nothing.** The `Z:` block is gone, and with it execute's now-unused
  `-ProvServer` / `-SmbUser` / `-SmbPass` parameters, the `smb-cred.dpapi` blob the
  driver planted for them, and the decrypt in `client/mast-run-detached.ps1`. Callers
  updated: `server/prov/driver.py`, `server/check-and-provision.ps1`,
  `vm/run-prov-test.py`.
- **A new `mast-shared-mount` provider (order 2210)** owns the letter. It installs
  `mast-mount-shared.ps1` on the unit, registers it as a **SYSTEM at-startup scheduled
  task**, and additionally sets it as an **nssm `Start/Pre` hook on `mast-unit`**. Both
  run in the LocalSystem logon session the services share, so the mapping is visible
  where it is used; the hook closes the boot race deterministically, the task covers
  every other LocalSystem consumer. The script resolves `controller_host` from
  `C:\WIS\config.toml` (the config-bootstrap profile, already cross-checked against the
  DB `sites` doc), clears stale per-user mappings of the letter, and creates
  `Z:\MAST\<hostname>\` -- `Filer.accessible_shared_root()` tests that exact directory,
  so an absent one falls back to `C:` even with the share mounted.
- **A second credential.** The operational share is Samba `valid users = mast`,
  `guest ok = no`, so the machine account cannot authenticate and the provisioning
  server's read-only `mast-transfer` account is the wrong identity. `vault/creds.json`
  gains a `shared` block, and the driver plants it as a machine-bound
  DPAPI-`LocalMachine` blob (`shared-cred.dpapi`). The plaintext is **uploaded as a
  file** and zeroed and deleted once protected, rather than passed as a command-line
  argument. A missing `shared` block is FATAL.
- **`/persistent:no` on purpose.** Persistent reconnect is a per-user profile feature
  restored at interactive logon, which never happens for a service account -- it is
  exactly what produced the *Unavailable* rows. The task re-establishes the mapping at
  boot instead, with `RestartCount` covering a controller that is not up yet.

**Rejected:**

- **Keeping the mapping in execute and simply pointing it at the controller.** Rejected
  because the session is wrong, not just the target: execute runs as the autologon
  `mast` user and the services run as LocalSystem, so a correct mapping made there is
  invisible to `Filer`. This is the fix the original issue write-up implied, and it
  would have looked right and changed nothing.
- **A persistent mapping (`/persistent:yes`).** Rejected on the evidence of the
  *Unavailable* rows: persistent reconnect is a per-user profile feature restored at
  interactive logon, which never happens for a service account. It is what produced the
  broken state, not what would fix it.
- **Reusing the provisioning server's `mast-transfer` account.** Wrong identity -- the
  operational share is Samba `valid users = mast`, `guest ok = no`, so the machine
  account cannot authenticate and the read-only transfer account has no business on the
  science share. A second credential was accepted instead.
- **Passing the share password as a command-line argument.** Rejected for the same
  reason as the SMB password in the detached-execute design: the plaintext is uploaded
  as a file, then zeroed and deleted once protected into a DPAPI-`LocalMachine` blob.
- **The scheduled task alone, or the nssm `Start/Pre` hook alone.** Both are used
  together on purpose: the hook closes the boot race deterministically for `mast-unit`,
  and the task covers every other LocalSystem consumer. Either alone leaves a gap.
- **Failing the run when the share cannot be mounted.** Rejected -- a unit provisioned
  in the lab cannot reach its site controller, so mounting is best-effort
  (`shared_mount_warn`) while *installing the mechanism* is not.

**Unsettled:**

- **The deeper fix belongs upstream and is not made here.** `Filer` should take a UNC
  path from `controller_host` instead of a drive letter, and should log loudly rather
  than silently fall back to `C:`. A drive letter is a per-session concept being used to
  carry machine-wide configuration. Filed against MAST_common; until it lands, this
  provider makes the letter mean one thing on every unit.
- **The silent `C:` fallback survives this change.** Everything here makes the mapping
  correct and visible; nothing makes `Filer` complain when it is not. So the failure
  mode that hid three frames on 2026-07-14 is narrowed, not removed.
- **LocalSystem was confirmed on mast03 only**, and the belief that all four services
  on all four units run that way rests on nssm installing them with no `ObjectName`.
- **The VM harness does not plant the share credential**, so `mast-shared-mount` will
  always report a warn there. That is correct -- there is no controller to reach -- but
  it means the mount path is never exercised in the harness.
- **Existing units converge only on the next run**, and until then the fleet keeps its
  drifted per-user mappings.

**Implications:** Verify fails only on install-level problems, and always records the
last mount outcome -- a silently unmounted `Z:` is the failure mode being designed out.
