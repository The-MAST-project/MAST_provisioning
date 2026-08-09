---
decided: 2026-08-03
status: accepted
issue: MAST_provisioning#7
areas:
  - providers
  - services
  - failure reporting
---

# The nomachine provider pins `server.cfg` and verifies the serving state, not the service state

**Why:** All four production units (mast01-04) stopped accepting NoMachine
connections between 2026-07-30 and 2026-08-03, while SSH stayed up. The cause is
a NoMachine 9.0.188 defect: `ServerHistoryCleaner` periodically trims
`C:\ProgramData\NoMachine\var\log\history` by writing `history_new` and renaming
it over `history`. On these units that rename fails on **every** attempt (41/41
on mast02, 14/14 on the others; `Error is -1, 'Unknown error'`), and the failure
path in `libnxdb.dll` dereferences null -- `nxserver.bin` dies with 0xC0000005 at
`libnxdb.dll+0x6cb52`, identically on every unit. `nxservice` respawns it, and
after three crashes logs `Too many failures in session [0]` / `checkNxserver
failed` and **stops respawning**. The unit is then left with `nxservice` Running
and `nxhtd` alive, but `nxserver`/`nxnode`/`nxd` disabled and nothing listening
on 4000.

Three properties of the provider turned that upstream bug into a silent
fleet-wide outage:

1. **The idempotency gate could not see it.** `Test-NoMachineInstalled` checks
   only that `nxserver.exe` exists and `nxservice` is Running -- both true in the
   disabled state. Re-provisioning logged `NoMachine already installed and
   nxservice running; skipping installer execution` and repaired nothing.
2. **The license restart hit the wrong service.** `Install-License` restarted the
   first service matching `NoMachine|nx`, which resolves to `nxhtd` (the web
   server on 4443), so `nxserver` never picked the license up and a disabled
   server stayed disabled.
3. **Verification asserted the wrong thing.** `verify-nomachine.ps1` passed if
   any `nx*` service existed, so it reported healthy throughout the outage. This
   is the "post-deploy smoke test" that the archived 2026-05-24 entry deferred
   ("whether `enterprise-desktop` actually installs the server side correctly");
   deferring it is what let the regression go unnoticed.

**What:**

- **`provide-nomachine.ps1` pins two `server.cfg` keys** via a new idempotent
  `Set-ServerCfgKey` (backs up once to `server.cfg.mast-prov.bak`, rewrites the
  shipped commented default in place, appends if absent):
  - `SessionHistory 0` -- disables session history, so the cleaner never runs and
    the crashing rename path is never reached. This is trigger avoidance, not a
    fix; the null deref is NoMachine's.
  - `UpdateFrequency 0` -- disables the update/version check, per NoMachine's own
    documentation of the key.
- **`Test-NoMachineServing`** is the new correctness predicate: `nxserver
  --status` must report `Enabled service: nxd`. `Test-NoMachineInstalled` keeps
  its old meaning and stays the installer success probe (requiring `nxd` during
  install would never become true), but it no longer decides whether the unit is
  healthy.
- **`Restart-NoMachineServer`** restarts the `nxservice` **service** and then runs
  `nxserver --startup`. The order matters and is the non-obvious operational
  finding: the "too many failures" latch lives in the running `nxservice`
  process, so `nxserver --startup` alone answers `NX> 500 NoMachine server is
  disabled` and merely sets the boot start-mode. Restarting `nxservice` clears
  the latch -- **a machine reboot is not required**, which is what the on-site
  recovery had been relying on.
- **The provider now repairs, not just installs.** Config is applied before any
  restart, and a closing step restarts the server if the config changed or the
  unit is not serving. Re-running the module on a disabled unit brings it back.
- **`verify-nomachine.ps1` asserts the serving state**: `nxd` enabled, something
  listening on 4000, and both `server.cfg` keys at their pinned values; it
  reports every failure at once and exits 1. It also reports the license expiry
  and stops looking for `.lic` files under `C:\ProgramData\NoMachine\licenses`,
  a path that does not exist on these units (the license is `etc\server.lic`).

**Rejected:**

- **`SessionHistory -1` (retain forever, never trim)** instead of `0`. It also avoids
  the crashing rename path while keeping the history, and it is the alternative to
  reach for if session history ever acquires audit value. Rejected because the units
  are reached through a single shared `mast` account, so the history records almost
  nothing worth having, and unbounded retention adds a second growth problem.
- **Waiting for an upstream fix.** The null deref is NoMachine's and belongs upstream,
  but the fleet was down and a vendor fix has no date. Trigger avoidance is explicitly
  recorded as such, so nobody later mistakes the pinned key for a root-cause fix.
- **Keeping `Test-NoMachineInstalled` as the health predicate** and tightening it to
  require `nxd`. Rejected because it would never become true *during* install, which
  is what that predicate is for. Two questions -- "did the installer succeed?" and "is
  this unit serving?" -- needed two predicates rather than one overloaded one.
- **Restarting `nxserver` via `nxserver --startup` alone.** Measured as insufficient:
  the latch lives in the running `nxservice` process, so the command answers
  `NX> 500 NoMachine server is disabled` and only sets the boot start-mode.
- **Rebooting the machine to recover**, which is what the on-site procedure had been
  doing. Establishing that a `nxservice` restart clears the latch removes a reboot
  from the recovery path.
- **Leaving the `.lic` search path alone.** It looked under
  `C:\ProgramData\NoMachine\licenses`, which does not exist on these units.

**Unsettled:**

- **Why the rename fails 100% of the time is still unexplained.** Deterministic rather
  than racy, so it points at a persistent open handle on `history` rather than a
  Defender scan race -- but that is an inference, not a diagnosis.
- **The upstream report has not been filed.** The evidence is preserved on the units in
  `var\log\trace.log` (stack + fault address per crash), `server.log` (the rename
  failure immediately preceding each crash), and `service.log` (the give-up).
- **The update check being off means new NoMachine releases must be noticed manually.**
  Deliberate -- the version nag was unwanted and the module pins `9.0.188` as a staged
  asset anyway -- but it means a future fix for this very bug will not announce itself.
- **`SessionHistory 0` means no NoMachine session history on the units:** who connected
  and when is no longer recorded by NoMachine.
- **The fleet was recovered by hand on 2026-08-03** (both keys set, `nxservice`
  restarted) and all four units serve on 4000 again; the provider changes make that
  recovery reproducible, but they have not yet been the thing that performed it.

**Implications:** Verify now fails loudly on a unit in this state instead of reporting
healthy, so a recurrence surfaces at the next provisioning or verify pass rather than
the next time someone tries to connect.
