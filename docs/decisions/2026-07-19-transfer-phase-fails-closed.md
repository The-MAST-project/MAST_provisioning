---
decided: 2026-07-19
status: accepted
issue: MAST_provisioning#10
areas:
  - transfer
  - failure reporting
  - orchestration
---

# The transfer phase fails closed: whitelist `OK` rather than blacklist two failures

**Why:** A code review before switching the autonomous loop on found the SMB
transfer phase was the only phase that failed *open*. `prov.driver._transfer`
rejected exactly two pull outcomes (`NET_USE_FAIL`, `ROBOCOPY_ERROR`) and let
everything else fall through to `TRANSFER_OK` -- so `NET_USE_HUNG`,
`DISK_INSUFFICIENT`, and (worst) a **missing/garbled `PULLRESULT` marker** were
all treated as successful transfers, and the driver would proceed to *execute*
against a staging dir that was never verified as copied. The remote rc from the
pull is not even checked. Every other phase already fails closed (smoke treats a
missing marker as `<missing>`->FAIL; execute requires `DETACHED_REGISTERED` + a
`status=="done"` poll). This is the one gap that matters for unattended runs. The
PowerShell driver (`server/check-and-provision.ps1`) has the identical logic --
the Python port faithfully reproduced it.

**What:** `_transfer` now **whitelists the single documented success outcome**:
`TRANSFER_OK` requires `outcome == "OK"` (the pull script's own success value;
robocopy rc 0-7). Any other outcome -- or an unparseable/absent marker -- logs
`TRANSFER_FAIL` (with a specific `reason`: `net_use_failed`, `net_use_hung`,
`robocopy_error`, `disk_insufficient`, or `unrecognized_pull_result`) and stops
the unit before execute.

Landed alongside two transport-hygiene fixes and a test-harness addition, all in
the same review pass:

- `prov.transport` no longer `sys.exit()`s at import when pywinrm is missing --
  it raises a catchable `ImportError`. `sys.exit` on import killed any tool/test
  that merely imported the module and broke the module's stated import-purity.
- `dump_json_file` writes `newline="\n"` so a Windows prov server cannot emit
  CRLF, matching the UTF-8-no-BOM + LF standard already used by
  `write_status_atomic`.
- New `server/prov/tests/test_driver_flow.py`: an in-process `FakeSession`
  (subclassing `SshSession`, no paramiko) drives `Driver._process_unit` through
  the full phase flow, covering the happy path and the transfer / execute / smoke
  / register / reachability failure branches -- the orchestration layer the
  earlier suite left entirely to the VM run. Suite: 74 passed, `ruff check` clean.

**Rejected:**

- **Adding the missing failure outcomes to the blacklist** (`NET_USE_HUNG`,
  `DISK_INSUFFICIENT`, and so on). The minimal fix, and rejected as the wrong shape:
  a blacklist is only as complete as the last person to update it, and the worst case
  found here -- an absent or garbled marker -- is not an outcome that can be listed at
  all. Whitelisting the one documented success value makes the unknown case fail by
  construction.
- **Keeping bug-compatibility with the PowerShell driver.** The identical logic exists
  in `server/check-and-provision.ps1`, and parity was the port's normal discipline. It
  was broken here deliberately: the Python driver is the go-forward orchestrator and the
  PS driver is slated for retirement, so the correct behavior wins over the matching one.
  Fixing both would have meant carrying the change through a component being deleted.
- **Checking the remote rc instead of the marker.** Available and not chosen -- the pull
  script already computes its own outcome from robocopy's rc semantics (0-7 is success),
  and re-deriving that on the driver side would duplicate the rule in a second place with
  a different notion of which codes are benign.
- **Running `ruff format`.** Intentionally not run: this repo lints with `ruff check`
  only and is not format-managed, so reformatting would bury a correctness change in
  whitespace.

**Unsettled:**

- **The VM negative test is the acceptance gate and has not run.** Break the pull,
  confirm the phase fails closed and does not execute. Until then the change is argued
  from the code, not demonstrated.
- **A future pull-script change that adds a new success outcome must also be added to
  the whitelist**, or transfers will fail closed on a success. This is the intended
  direction of failure, but it is a coupling between two files that nothing enforces.
- **The PowerShell driver keeps the fail-open bug** for as long as it exists. Anyone
  running it gets the old behavior, and nothing warns them.
- **Log/telemetry change:** two `TRANSFER_FAIL` activity reasons were unified into the
  `{reason}_rc_{rc}` form, so any consumer parsing the old strings breaks. No such
  consumer was known.

**Implications:** A transfer that used to be silently accepted (hung mount, full
disk, lost marker) now fails the unit loudly and is retried next cycle instead of
executing against a bad payload.
