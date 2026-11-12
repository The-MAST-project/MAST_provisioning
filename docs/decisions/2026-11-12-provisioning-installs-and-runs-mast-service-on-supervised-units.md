---
decided: 2026-11-12
status: accepted
issue: MAST_provisioning#82
areas:
  - services
  - hardware startup
  - service logon sessions
supersedes:
  - 2026-08-30-provisioning-registers-no-mast-service
  - 2026-08-12-one-nssm-service-supervises-an-interactive-monitor
---

# Provisioning installs and runs mast-service on supervised units

**Why:** the record this supersedes removed every MAST service and forbade registering one, for two reasons: a running `mast-unit` commanded hardware on process start (`MAST_unit#132`), and a registered service was a competing path into processes the operator ran by hand (#159). The supervisor (`MAST_supervision`, `epic:supervision`) is now the one owner of those processes, and the unit app no longer moves hardware on process start: a `production` unit stays `INITIALIZED` until `PUT /unit/startup`, apart from the FCU stage homing at construction, which the team accepted. The supervisor has to start at boot and be restarted when it dies, and only a service does that. So the no-services rule is overturned (team decision, 2026-11-04), for one service on the units that opt in.

**What:**

- **Provisioning has full authority over `mast-service`:** it installs, removes, stops and starts it. The registration itself (nssm, LocalSystem, automatic start, the stop and restart parameters) belongs to `MAST_supervision`, whose `install/install-mast-service.ps1` the new `mast-service` provider runs. Provisioning registers nothing itself, and `test_no_service_registration.py` still forbids any `nssm install` under the provider tree.
- **One machine at a time, through the registry's `supervised` flag** (`2026-11-12-the-registry-says-which-units-are-supervised`). The build puts `-Supervised` on the command and verify of `mast-service` and `mast-services-finalize`, so a flip changes both modules' hashes and drift re-runs them.
- **Unit machines only.** Spec machines are a separate effort.
- **The run brackets the service.** `mast-services-standdown` (20) stops it, never deletes it: a supervisor left running would restart what the run stops or replaces. The `mast-service` provider (2220, after `mast` lays down the supervision checkout) installs it on a supervised unit and fails when the checkout has no installer; on any other unit it removes it through provisioning's own `Remove-MastService`, not the installer's `-Uninstall`, so removal works on a checkout that predates the installer. It never starts the service. `mast-services-finalize` (9500) starts it on a supervised unit and asserts it absent otherwise, and still asserts the four legacy services absent.
- **The name has one accessor,** `Get-MastSupervisorServiceName` in `tools/mast-service-names.ps1`, and is deliberately not in `Get-MastServiceNames`: that list feeds the driver's phase 2b and the standdown, both of which delete. `test_no_service_registration.py` allows a start of the service only in finalize.

**Implications:**

- **A failed module does not leave the service down.** The unit-side loop runs every command whatever the previous one returned, so finalize runs. Only a run that dies outright (a timeout, a lost unit) leaves the service stopped. The driver does not restart it then, because a timed-out detached run may still be executing modules; the next run or a reboot starts it.
- **Every executing run stops and restarts the supervised stack**, including a `production` app, because standdown and finalize are `always`.
- **Inert means inert by convention.** A `production` app commands no hardware until `startup`, but any client calling a high-level route (`MAST_unit#395`, autostartup) starts it up; endpoint admission is not built.
- **The provider is hash-driven, not `always`.** Its hash covers the flag and `tools/mast-repos.tsv`, so a supervision pin that changes the installer re-runs it.
- **The verify checks a contract the installer has not landed yet.** `verify-mast-service.ps1` expects nssm to run `<Top>\.venv\Scripts\python.exe -m supervision.service` from `<Top>` as LocalSystem with automatic start. No unit is supervised until the supervision pin carries the installer.
- **The four legacy services stay removed,** with the same gate on the pre-rename names.

**Rejected:**

- *Stopping the service in the driver's phase 2b.* `_stand_down` runs before every skip return, so a dry run or an out-of-window cycle would leave a supervised unit dark.
- *A verify on the provider that asserts the service is running.* The provider never starts it; finalize's verify asserts running.
- *Adding `mast-service` to `Get-MastServiceNames`.* That list is the removal list.
