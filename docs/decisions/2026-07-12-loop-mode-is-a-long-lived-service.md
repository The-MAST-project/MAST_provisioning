---
decided: 2026-07-12
status: accepted
issue: MAST_provisioning#10
areas:
  - orchestration
  - scheduling
  - services
  - platform independence
---

# The autonomous loop is a long-lived `--loop` service, not a periodic-fire scheduled task

**Why:** Item 8 -- the last gate for the autonomous provisioning goal. The driver
needs to run continuously on a cadence (the requirements doc's "long-lived service
beats periodic-fire scheduler"), replacing the PowerShell `install-scheduled-task.ps1`
+ Task Scheduler path with a platform-agnostic Python service.

**What:** `server/check_and_provision.py --loop` runs `Driver().run()` cycles on
`--interval-seconds` (default 1800), via `prov.driver.run_loop`. A fresh Driver per
cycle (fresh run_id / log dir); per-unit maintenance windows already gate the
disruptive steps, so the loop just fires on cadence and each unit provisions only
inside its window. A cycle that throws is logged and does NOT stop the loop (a
service must stay up). SIGINT/SIGTERM set a stop event used both as the between-cycle
check and the interruptible inter-cycle sleep (`ev.wait`), so a stop signal exits
promptly instead of waiting out the interval. `--max-cycles N` bounds a run
(supervised one-shot / testing). The per-OS **service wrapper** is the only part
that differs by platform -- example `server/deploy/mast-provision.service` (systemd)
and NSSM instructions in `server/deploy/README.md`; the loop itself is portable.

**Rejected:**

- **Keeping Task Scheduler / `install-scheduled-task.ps1`** and firing the driver
  periodically. Rejected on the requirements doc's reasoning and on platform grounds:
  a periodic-fire scheduler is a second, OS-specific piece of state that has to agree
  with the driver about cadence and overlap, and it does not exist on Linux. A
  long-lived process owns its own cadence and can be signalled.
- **Letting a throwing cycle stop the loop.** The safer-looking behavior, and wrong for
  a service: an unattended fleet where one bad cycle silently ends all future cycles is
  worse than one where a bad cycle is logged and the next runs. The failure stays
  visible in the log rather than in the absence of activity.
- **A plain `sleep` between cycles.** Rejected because it makes a stop signal wait out
  the full interval -- up to 30 minutes to shut a service down. `ev.wait` on the stop
  event gives the same pacing with prompt termination.
- **Having the loop implement its own maintenance-window gating.** Not needed and not
  done: per-unit windows already gate the disruptive steps inside a cycle, so the loop
  stays a dumb cadence and there is one place where "may this unit be touched now?" is
  answered.
- **A cross-platform service wrapper in Python** (a service abstraction layer). Rejected
  as the wrong place to spend portability effort -- systemd and NSSM already do this
  well, and the wrapper is genuinely the only platform-specific part, so it is left as
  deployment configuration with an example for each.

**Unsettled:**

- **Nothing has run on the real fleet.** Validation is two dry-run cycles on the
  mast-unit VM (each a fresh run to `exit_code=0`, then a clean stop at `--max-cycles`).
  Real cadence against real units, and reboot survival, await a real unit -- VM reboots
  do not return reachable, understood as a harness artifact.
- **Flipping it on is a deployment step, so the loop is not actually running.** Installing
  the service and setting `--interval-seconds` and `MAST_SERVER_ROOT` is manual and
  undone; the code being ready and the fleet being unattended are different states.
- **The default 1800 s interval is a guess.** It was not derived from how long a cycle
  takes or how often units need attention.
- **Overlap is prevented by leases, not by the loop.** A cycle that outruns the interval
  is assumed to be handled by the availability and execute leases rather than by the loop
  refusing to start another; that composition has not been exercised.
- **The PowerShell driver and `install-scheduled-task.ps1` remain in place** until
  retired, so two activation mechanisms exist simultaneously.

**Implications:** With items 1-8 landed, the Python driver covers the full autonomous
path. The remaining distance to unattended operation is deployment, not code.
