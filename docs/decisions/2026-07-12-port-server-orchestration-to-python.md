---
decided: 2026-07-12
status: accepted
issue: MAST_provisioning#10
areas:
  - orchestration
  - platform independence
  - transport
---

# The provisioning server orchestration moves to Python, so the control plane is platform-agnostic

**Why:** The autonomous provisioning loop must be platform-agnostic -- the prov
server may run on Linux -- while the provisioned units stay Windows. The driver
was PowerShell (`server/check-and-provision.ps1`), which ties the control plane
to Windows. **Standing forward requirement (per Eli):** the provisioning server
must be genuinely platform-agnostic -- all paths and mechanisms run end-to-end
against the Windows units with no per-platform patching or extra code.

**What:** A new Python package `server/prov/` becomes the server-side control
plane, replacing the PowerShell driver. Landed so far (this commit):

- **`transport.py`** -- the WinRM/SSH transport, **lifted** out of `vm/vm_lib.py`
  (which was labeled throwaway test scaffolding) so the shipped driver owns it.
  `vm_lib.py` is now a thin shim that re-exports `prov.transport` and keeps only
  the VirtualBox (test-only) helpers; the `vm/` harness is unchanged.
- **Pure-logic modules** ported 1:1 from the PowerShell libs, each with pytest
  mirroring the Pester tests: `retention.py`, `proxy_assert.py`, `winrm_flap.py`,
  `staging_size.py`, and `maintenance_window.py`. The maintenance-window port
  drops the IANA->Windows timezone shim (`mast-timezone.ps1`): Python's `zoneinfo`
  resolves IANA ids natively.
- Still to land: `logevents.py` (server-side of `mast-log.ps1`), `driver.py` (the
  orchestrator), and the `check_and_provision.py` CLI. The PowerShell driver stays
  in place and remains authoritative until the Python driver is validated on a
  real run (the deferred VM test); then it retires.

**Scope boundary (what stays PowerShell / infra):** the steps the driver *drives*
stay as-is and are invoked, not rewritten -- `build-mast.ps1` (produces Windows
staging; shelled via `pwsh`/`powershell.exe`), `mast-pull-staging.ps1` and
`execute-mast-provisioning.ps1` (run on the unit), all providers. **Transfer is
SMB for all platforms** (unit pulls via `net use`+robocopy from `\\server\share`;
a Linux server serves the share via Samba) -- one universal transfer path, share
hosting is deployment infra, not driver code.

**Rejected:**

- **Rewriting the whole system in Python, providers included.** Rejected as the
  scope boundary above: the providers install Windows software on Windows units and
  gain nothing from being Python, while a full rewrite would put every provider's
  proven behavior back in play at the same time as the control plane changes. Only
  the *control plane* is platform-bound, so only the control plane moves.
- **Keeping the PowerShell driver and making it portable via `pwsh`.** Technically
  possible -- PowerShell 7 runs on Linux -- and rejected because it buys a portable
  interpreter while keeping every Windows-shaped assumption in the driver's own
  code (`SystemDrive\MAST`, path handling, the WinRM stack), and it makes `pwsh` a
  hard dependency of the server for no gain over Python.
- **Replacing the SMB pull with `scp`/`sftp` now that the transport can do it.**
  Deliberately not taken here: SMB is one transfer path that works identically from
  a Windows or a Linux server (Samba serves the share), and share hosting is
  deployment infrastructure rather than driver code. Changing transfer at the same
  time as the driver would have coupled two independent risks.
- **Cutting over to the Python driver immediately.** The PowerShell driver stays
  authoritative until a real run validates the Python one. The two coexisting is
  temporary duplication accepted on purpose, so the cutover is a decision with
  evidence behind it rather than a side effect of the port landing.

**Unsettled:**

- **Port gotchas being designed for, not yet proven:** the driver's own logs/status
  were under `SystemDrive\MAST` (Windows-only), so the Python driver resolves a
  portable server root; remote Windows paths must stay literal strings and never
  `pathlib.Path` (Path mangles `C:\...` and UNC on a Linux server); `zoneinfo` needs
  the `tzdata` pip package on Windows (no bundled db there) or IANA ids fall back to
  server-local with a `MAINT_TZ_WARN`, which would silently undo the timezone fix;
  reads stay BOM-tolerant because PS 5.1 writes a BOM, while the Python driver writes
  plain UTF-8 + LF with atomic `os.replace`; the PowerShell exe is resolved portably
  (`pwsh` on Linux, `powershell.exe` on Windows); structured results from unit-side
  scripts come back as JSON over the session rather than as live PS objects; and
  `-AllowReboot` can drop the session mid-run.
- **The platform-agnostic claim is untested on Linux.** Every path here was designed
  for it and none has been exercised from a Linux prov server -- the standing
  requirement is a requirement, not a measurement.
- **`_preflight_smb` failure does not short-circuit the cycle.** On a Windows server
  a failed SMB preflight sets `exit_code` but the run still attempts every unit, so
  one root cause produces N cascading `TRANSFER_FAIL`s. Flagged rather than silently
  changed, because aborting the cycle early is a behavior change.
- **`transport.py`'s WinRM probes mutate the caller's `cred` dict in place**
  (`_winrm_probe_once` / `wait_for_winrm` write `cred["user"]`, onto `Driver.unit_cred`)
  to make the working username form sticky. Intended, but a shared-mutable side effect
  that may surprise a future caller; possibly WONTFIX.
- **Two drivers exist at once** until the cutover, and nothing prevents someone from
  running the wrong one.

Two changes the port surfaced are decided separately the same day and recorded in
`2026-07-12-ssh-first-transport-and-utf8-no-bom.md`: SSH-first transport, and a
UTF-8-no-BOM + LF standard for all MAST JSON. Both belong to the transport and data
layer rather than to the orchestration move, which is why they are their own record.

**Implications:** The control plane stops being Windows-bound, and the transport becomes
a shipped component with one owner instead of test scaffolding the driver borrowed. The
pure-logic modules gain pytest coverage mirroring their Pester originals, so the two
implementations can be compared while both exist.
