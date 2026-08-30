---
decided: 2026-08-26
status: superseded
issue: MAST_provisioning#159
superseded_by: 2026-08-30-provisioning-registers-no-mast-service
areas:
  - services
  - hardware startup
  - failure reporting
---

# Provisioning does not run the MAST unit service, and does not test it

`mast-unit` is registered `SERVICE_DISABLED`, is stopped and disabled before the first module runs, and is never started by a provisioning run. Every check that needed it running is gone.

**Why:** a running unit service commands hardware on process start -- `The-MAST-project/MAST_unit.2024-12-12#132`: the mirror covers open and the mount homes, on process start rather than on command -- and there is no interlock anywhere in the stack to make that safe. So the previous design had a provisioning module driving real hardware on an unattended machine: a mount that is clamped or obstructed gets commanded to home, cabling gets pulled by an unexpected slew, and the covers are left open if the run does not end cleanly.

The window was not small. `provide-mast.ps1` registered the service `SERVICE_AUTO_START` and started it at order 2200; `mast-services-finalize` flipped it to Manual and stopped it at 9500. That was deliberate -- the per-provider verifies and `verify-diagnostics.ps1`'s heartbeat were meant to run against a live service -- but it left the service up for the whole tail of a run, and `Auto` meant a reboot brought it straight back. Two further gaps made it worse than intended:

- The `nssm set ... Start` call sat inside the `if ($null -eq ${existingSvc})` branch, so a unit that already had the service never had its start mode re-stated. mast08 arrived `Running/Auto` and stayed that way through a whole run (#140), and nothing in the run had asked for it.
- Nothing stood the unit down before the build and the transfer, which is the *longest* phase. A unit that arrived running had been commanding hardware for all of it before any module could intervene.

The intended fix used to be the other direction: separate connect from startup so that process start moves nothing (`The-MAST-project/MAST_unit.2024-12-12#118`, `epic:unit-lifecycle`). That work is stalled on its state model, and provisioning should not wait on it. The requirement is also narrower than the old design assumed: provisioning owes a best-effort *environment* -- dependencies, prerequisites, the clone, the venv, the registered service and its configuration -- not a proven-working service. A unit running `mast-unit` means business; with no interlocks, a service that starts and reports OK is fully operational and ready to receive assignments, and reaching that state is an operator's decision.

**What:** three enforcement points, one per part of the run.

- **`mast-services-standdown`**, a new provider at order 20 (`always`), stops each service in the stand-down set and sets it `Disabled`, reading the end state back from `Win32_Service.StartMode` rather than trusting the call. `Set-Service`, not nssm, because nssm arrives at order 1200. A service that is not registered is a SKIP -- that is a first provisioning.
- **`Driver._stand_down`** does the same over the transport at phase 2b, after `_reclaim_availability` and before `_build`, closing the transfer window the modules cannot reach. It emits `STANDDOWN_OK` / `STANDDOWN_FAIL` and **fails the unit closed** with `UNIT_FAIL reason=standdown_failed`: provisioning a machine whose telescope may be moving is exactly the outcome this exists to prevent, and giving up before the build costs one line in the fleet report rather than an hour.
- **`mast-services-finalize`** keeps order 9500 but stops *applying* a posture and starts *asserting* one, per service.

The expected start mode per service moved out of the provider directory to `tools/mast-service-names.ps1` as `Get-MastServiceExpectations` (`mast-unit` -> `Disabled`, the three prerequisite services -> `Manual`), staged into both providers by `repofiles` so there is one table rather than two copies. `Get-MastStandDownServiceNames` derives the stand-down set from it, so a service joining the set is a one-line table edit. `driver.py` carries `STAND_DOWN_SERVICES` because it runs before any payload has reached the unit and cannot read the table; `server/prov/tests/test_stand_down.py` parses the PowerShell table and fails if the two drift.

In `provide-mast.ps1` the start-mode assertion moved *out* of the install-only branch and became `SERVICE_DISABLED`, and it throws if the read-back is anything else. `Start-Service` and the moved-checkout `Restart-Service` are gone.

Section 7 of `verify-diagnostics.ps1` -- the `:8000` `/mast/api/v1/unit/status` heartbeat -- is deleted along with its `-RequireUnitHeartbeat` switch, its `-MastUnitPort` parameter and the now-unused `Add-DiagWarn` helper. This reverses the disposition recorded for `mast-unit-heartbeat` in `2026-08-11-verifies-assert-what-provisioning-owns.md`, which expected it to graduate from a warning to an error: there is no listener to probe and no health to infer, so the check has no subject rather than a lenient one. It was the only live-service dependency in the system.

**Implications:**

- **A run surfaces nothing about whether the unit service works.** That is the trade, and it is accepted. What provisioning still asserts is what it owns dead: the service registered and pointed at the mast-clone venv interpreter (`verify-mast.ps1`), the firewall rule on 8000, the `Z:` `Start`/`Pre` hook, clone and venv drift. `mast-validation` (2900) and `mast-autofocus-validation` (3000) are untouched and remain the end-to-end signal -- they drive production code paths against bundled FITS through the unit's venv, with no service and no hardware.
- **The fleet's resting state changes from `Stopped`/`Manual` to `Stopped`/`Disabled` for `mast-unit`.** An SCM start now needs an explicit enable first, which is the point: in a stack with no interlocks, requiring a deliberate enable *is* the interlock. Today's real path is unaffected -- the unit is run by hand under the VS Code debugger and `mast-service.ps1` is dormant -- but a future NSSM cutover has to enable before starting.
- **A new way for a run to abort.** `standdown_failed` fails before the build, so its cost is bounded, but a unit whose service cannot be stopped is now skipped rather than provisioned.
- **The three prerequisite services stay `Manual` for now.** `mast-pwi4`, `mast-phd2` and `mast-pwshutter` move nothing by coming up, and they are being deleted with the supervisor topology (#82), where they become children of `mast-monitor` rather than services. They join `mast-unit` at `Disabled` in that change; #159 carries the two consequences it needs (dropping `AppDependencies mast-pwi4`, and the `Start-Service mast-phd2` nudge in the PHD2 port check).
- **`mast-services-finalize` is no longer a temporary measure.** Its `module.json` said manual start was a development-stage measure and the provider was expected to be relaxed so services returned to automatic start once battle-tested. That is not the plan: what decides when a process runs is a supervisor, not a start mode.
