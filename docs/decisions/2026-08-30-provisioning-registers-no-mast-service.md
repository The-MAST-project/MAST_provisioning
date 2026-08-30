---
decided: 2026-08-30
status: accepted
issue: MAST_provisioning#159
areas:
  - services
  - hardware startup
  - service logon sessions
supersedes: 2026-08-26-provisioning-does-not-run-the-mast-unit-service
---

# Provisioning registers no MAST service, and removes the ones already on the fleet

The four MAST nssm services -- `mast-unit`, `mast-pwi4`, `mast-pwshutter`, `mast-phd2` -- are no longer registered by any provider, and are deleted from every unit on its next ordinary run. The pre-rename names `PWI4`, `PWShutter` and `PHD2` go too, but only when nssm-hosted. The end state on every unit, production and dev alike, is that no MAST service exists.

**Why:** the record this supersedes stopped provisioning *running* `mast-unit`, on hardware-safety grounds -- process start opens the mirror covers and homes the mount (`MAST_unit#132`) with no interlock anywhere in the stack. That reasoning is unchanged and is not restated here. What it got wrong was the resting place: it left `mast-unit` registered but `Disabled`, and left the three prerequisite services registering `SERVICE_AUTO_START` and running during a run, on the reasoning that they *move nothing by coming up*. That is true of the hardware and false of the software.

None of the four processes is started by its service:

- `mast-unit` is run by hand under the VS Code debugger. `MAST_unit/service/mast-service.ps1` is not a fallback -- it is dormant *and* stale, still pointing at `C:\Users\mast\PycharmProjects\MAST_unit.2024-12-12` rather than the mast-clone layout.
- `mast-pwi4` and `mast-phd2` duplicate what the unit already does for itself: `MAST_unit/src/app.py`'s `start_supporting_processes()` calls `ensure_process_is_running(name="PWI4.exe", ...)`, and `MAST_unit/src/phd2/phd2.py` starts `phd2.exe` under a `WatchedProcess`.
- `mast-pwshutter` has had no consumer at all since the covers moved to PWI4's `mirrorcover` HTTP API (`MAST_unit#134`).

So a registered service is a **competing** path rather than a redundant one, and the competition has a specific failure: `ensure_process_is_running` (`MAST_common/process.py`) returns any existing process matching the name before considering a launch. A `PWI4.exe` raised by `mast-pwi4` lives in session 0 -- no interactive desktop, no `Z:` -- and a hand-run unit *adopts* it rather than starting one in its own session. The operator ends up with a PWI4 that can neither draw nor see the operational share, from a service they did not knowingly start. `Disabled` makes that require a deliberate `Start-Service`; removal makes it impossible.

Leaving them registered also pushes work onto the supervisor topology (#82), which says as much: *"a leftover `mast-pwi4` set to Automatic would contend with the monitor for the same process."* Every unit provisioned between now and that cutover would carry four registrations the topology has no use for. This change retires that item rather than deferring it, and needs no migration tool -- `mast-services-standdown` is `always: true`, so any non-empty run cleans the unit.

**What:** the same three enforcement points, doing removal instead of a start mode.

- **`mast-services-standdown`** (order 20, `always`) stops each service and deletes it. `sc.exe delete`, not `Remove-Service`, which is PowerShell 6+ where the fleet is 5.1 -- and spelled with the extension, because bare `sc` is an alias for `Set-Content`. nssm is not used: it arrives at order 1200 and this runs at 20. Deleting the service key takes nssm's `Parameters` subkey with it.
- **`Driver._stand_down`** does the same over the transport at phase 2b, before the build and transfer, and still fails the unit closed with `UNIT_FAIL reason=standdown_failed`.
- **`mast-services-finalize`** (9500) asserts absence rather than applying it. A second remover would hide a provider that had quietly re-registered a service mid-run, which is exactly what the end-of-run check exists to surface.

`tools/mast-service-names.ps1` keeps its role as the one table, now holding `Get-MastServiceNames`, `Get-MastLegacyServiceNames`, the `Test-MastNssmService` gate, `Remove-MastService` and `Get-MastRegisteredServiceNames`, staged into both providers by `repofiles`. `driver.py` duplicates the two name lists because it runs before any payload reaches the unit; `server/prov/tests/test_stand_down.py` fails if they drift.

Two decisions inside the change are worth stating separately.

**A pending deletion is a failure, not a pass.** `sc delete` against a service with an open handle elsewhere returns success but only *marks* the service; it stays enumerable until the last handle closes, in practice until a reboot. Both the provider and the driver read the registration back rather than trusting the exit code, and report `pending-delete`. The cost is that a unit can need one extra run; the alternative is a run that claims a removal that has not happened, which is the failure mode this repo keeps rediscovering (#55, #67, #62).

**The legacy names are gated on an nssm ImagePath.** `PWI4`, `PWShutter` and `PHD2` are not unambiguous the way the `mast-*` names are -- `PHD2` is a plausible name for a service installed by something else -- so they are deleted only when `Win32_Service.PathName` matches `nssm.exe`, which is the signature of a registration this repo made. Removing only the `mast-*` names would have stranded auto-starting services on precisely the units that predate the rename, which is where they do the most harm; retiring `tools/rename-mast-services.ps1` without absorbing its knowledge would have dropped that on the floor. The gate only ever *narrows* what is deleted, so its failure mode is a service left in place and visible on the next run.

**Implications:**

- **`tools/rename-mast-services.ps1` is retired.** It migrated legacy names *to* the `mast-*` names, which no longer exist.
- **The `mast` provider registers nothing.** It keeps the TCP 8000 firewall rule -- a hand-run unit still binds the port, and a supervisor later will too -- and loses the nssm install, the log redirection, the `AppDependencies mast-pwi4` line (a no-op on nssm 2.24, whose valid parameter is `DependOnService`) and the `Force`-path service stop.
- **`verify-mast.ps1` no longer asserts the service's interpreter.** Nothing is lost: it already asserts the venv interpreter exists at `<Top>\.venv\Scripts\python.exe` and checks the pins against it. What goes is only *"the service was re-pointed at the new layout"*, which has no subject.
- **`mast-shared-mount` loses its nssm `Start/Pre` hook**, which hung off `mast-unit`. It was already inert on the fleet -- the vendored nssm 2.24 rejects `AppEvents` outright (#55) -- so the SYSTEM at-startup task, always the real mechanism, now stands alone. **Its reach is worth being explicit about:** the mapping is SYSTEM-session only, and a hand-run unit is not a LocalSystem process. `Filer` still resolves its shared area through the `Z:` letter with a silent fallback to `C:\MAST` (`MAST_common#26` has not landed), so nothing here closes that gap; this change only stops the code pretending a service-bound path exists. Tracked as #173.
- **`nssm` (order 1200) still installs nssm.exe** although nothing now consumes it. It is left in place deliberately: the supervisor topology registers `mast-watcher` through it, and removing it here would be reversed by #82.
- **A new mechanical gate.** `server/prov/tests/test_no_service_registration.py` scans the provider tree and `tools/` for `nssm install`, the `SERVICE_*` start modes and a `Start`/`Restart-Service` against a `mast-*` name, so the property is enforced by CI rather than by review.
