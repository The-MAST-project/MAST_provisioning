---
decided: 2026-08-12
status: proposed
areas:
  - services
  - session isolation
  - the operational share
  - hardware startup
---

# One nssm service supervises an interactive monitor

**Why:** MAST processes have to start at boot, be restarted when they die, and still reach `C:`, the ImDisk RAM disk on `D:`, and the operational share on `Z:`. Today they do none of that: the unit is started by hand in an interactive session, which is the only reason it can see its drives.

Session 0 is what makes this awkward rather than routine. PWI4 and PHD2 are GUI applications and the ASCOM drivers expect an interactive desktop, so a service cannot host them -- "allow service to interact with desktop" has been deprecated since Vista and does not work for modern applications. `net use` mappings are per *logon session*, so a session-0 service cannot see `Z:` at all, whatever account it runs as, and `Filer` responds to an invisible drive by silently falling back to `C:\MAST` -- the failure behind the frames lost on 2026-07-14, recorded in the nssm-hook decision of 2026-08-09.

The current shape is four nssm services -- `mast-unit`, `mast-pwi4`, `mast-pwshutter`, `mast-phd2` (`server/providers/mast-services-finalize/mast-service-names.ps1`) -- with an ordering constraint noted in that file's own comments, and a fleet resting state of Stopped/Manual (#60). Each application got its own service because nothing owned them collectively. #68 and #60 are both symptoms of that arrangement rather than of any single provider.

Separately, `app.py` ties the whole hardware startup sequence into the FastAPI lifespan. That was a development-time shortcut to bring a unit up in one sweep, and it means process start *is* hardware motion: MAST_unit#132 records a provisioning restart opening the mirror covers, which then stayed open for 54 hours. Nothing may be allowed to restart the unit automatically while that holds.

**What:** one nssm service, `mast-watcher`, running as LocalSystem in session 0. It supervises exactly one child.

`mast-watcher` spawns `mast-monitor` into the interactive session --
`WTSGetActiveConsoleSessionId` -> `WTSQueryUserToken` -> `DuplicateTokenEx` -> `CreateEnvironmentBlock` -> `CreateProcessAsUser` with `lpDesktop = "winsta0\default"`. `WTSQueryUserToken` needs `SE_TCB_NAME`, which is why the watcher is LocalSystem and not a named account. pywin32 is already a dependency of this codebase, so nothing new is introduced to do it.

The point of the layering is that this token work happens **once**, for one known child. `mast-monitor` runs in session 1 under auto-logon and spawns everything below it with a plain `CreateProcess`, so its children inherit its session, its drive mappings and its environment. Drive visibility stops being an architectural constraint and becomes a property of the auto-logon session -- the configuration that demonstrably works today.

`mast-monitor` owns four processes: `PWI4.exe`, `ps3cli.exe`, `phd2.exe`, and the unit's Python process. `mast-pwshutter` does not appear: the covers move to PWI4's HTTP API (MAST_unit#134), verified on mast00 on 2026-08-12 driving three full open/close cycles with no PWShutter process running at all. Four services therefore become one.

Every remaining supervised process has a way to answer "are you working" -- PWI4 on :8220, ps3cli on :8998, PHD2's JSON-RPC socket, and the unit's own `/status`. `PWShutter.exe` was the only one with no such channel, so its removal is what lets supervision be health-based across the board instead of name-matching one special case. `ensure_process_is_running` accordingly becomes probe-driven, over three states rather than two: answers -> nothing to do; silent and absent -> spawn; **silent and present -> wedged, and must not be given a second instance**, because two PWI4s contending for one mount is worse than one that is stuck.

Maintenance reuses `Site.units_in_maintenance`, already in the site's MongoDB configuration and already consumed by `common/parsers.py` to skip a unit when expanding a unit specifier. A unit in maintenance means `mast-monitor` does not spawn or watch the unit process; the GUI applications stay up unconditionally, so the hardware can still be driven by hand. Setting and clearing the flag drives the unit through its own `/startup` and `/shutdown` rather than by killing the process -- the API stays available to test a repair, and nothing dies mid-exposure. The watcher never consults the flag at all: its job is unconditionally to keep the monitor alive, which is what keeps the operator's control surface up while everything beneath it is stopped.

Four behaviours the monitor has to get right, each for a specific reason:

- **Adopt, do not respawn.** On its own restart the monitor attaches to running children rather than starting or bouncing them. Restarting PWI4 disconnects the mount; doing that because a supervisor hiccuped, mid-exposure, is a self-inflicted lost night.
- **Take the restart veto from the unit.** Before bouncing anything the monitor reads the unit's activities from `/status` and refuses while `Exposing`, `Acquiring` or `Guiding`. The signal already exists; nothing new needs inventing.
- **Gate on readiness in the monitor, not the watcher.** Only session 1 can see `Z:`, so only the monitor can confirm the share answers and that `D:` is mounted *and formatted* before starting the unit. An nssm `DependOnService` on ImDisk proves the service started, not that the volume is ready.
- **Minimise to tray; the close button must not exit.** A supervisor that stops supervising because someone clicked X fails silently at exactly the wrong moment.

PHD2 moves out of the unit process. `PHD2Connector.__init__` currently builds a `WatchedProcess` and starts `phd2.exe` itself, so PHD2's lifetime is tied to the unit's -- which contradicts keeping the GUI applications up while the unit is stopped for maintenance. It becomes a client of a PHD2 the monitor owns.

Hardware startup is decoupled from process startup, in three stages: **import** does no I/O and starts no processes (MAST_unit#114); **construct** creates objects without touching a device; **connect/startup** powers, dispatches COM and moves things, and only on command. The second stage is the harder half and is not covered by #114: `Mount.__init__` currently calls `power_on()` on an outlet and dispatches the ASCOM driver, so merely constructing a `Unit` acts on hardware. Getting this right is what lets CI and hardware-free provisioning tests run the real code paths on a VM.

**Rejected:**

- *Everything as nssm services in session 0.* Cleanest operationally -- SCM restarts, boot ordering, no logged-on user, no auto-logon credential -- and unavailable, because the GUI applications cannot run there. This is the current shape, and the reason it rests at Stopped/Manual.
- *Everything interactive, supervised by Task Scheduler or a logon-time script.* Every drive letter works with no changes, which is its whole appeal, but there is no SCM-grade monitoring and the supervisor is itself unsupervised.
- *Per-application nssm services, kept and fixed.* No component owns the set, so ordering, health and maintenance have nowhere to live; and it does not address the GUI applications being unable to run in session 0 at all.
- *A service that launches each GUI application into the active session.* Equivalent to the watcher but repeats the token work per application, each with its own startup behaviour, instead of doing it once for one child.
- *Job objects with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` on the monitor's children.* The obvious way to stop orphans surviving a monitor restart, and it defeats adopt-don't-respawn: a monitor crash would take PWI4 down with it, disconnecting the mount.
- *`New-SmbGlobalMapping` instead of UNC paths.* Keeps the `Z:` letter and makes it visible to services, at the cost of a stored per-machine credential. MAST_common#26 removes the dependency on a drive letter entirely, which is the better direction.
- *`mast-monitor` owning the enclosure and the air conditioning.* Considered and placed elsewhere -- see below.

**Unsettled:**

- **The enclosure and HVAC belong to the control/scheduler sequence, not to a per-unit monitor.** The telescopes share one rolling roof (MAST_unit#132), so a per-unit owner is a race with expensive consequences, and "unit 7 is in maintenance" must not close the roof over units 1-6. The failure costs also differ in kind: a supervisor that fails does not restart processes, while an enclosure controller that fails leaves the roof open in rain. Two policies were decided here even though the work lands elsewhere: **the HVAC runs continuously except when the roof is open** -- the site is hot desert, and always-on removes a predictive control problem -- and **the roof closes when nothing is scheduled for at least half an hour**, which bounds target-of-opportunity latency rather than closing the moment the queue empties. Opening and closing are not symmetric: opening may be as clever as the scheduler likes, closing is safety and must not depend on the scheduler being healthy. The unit will also need to *read* enclosure state as a precondition for observing, though it should never drive it.
- **Blocked on MAST_unit#132.** Automated restart cannot be enabled while unit startup opens the covers; a supervisor would do it on every crash-restart, unattended, at any hour. MAST_unit#133 is the other half -- the covers are not closed on the way down either.
- **Blocked on the unit's `/shutdown` being one-way.** `do_shutdown()` sets `unit_shutdown_event`, which is never cleared anywhere, and cancels the unit timer; seven components return early from their timers while it is set. `/startup` afterwards reports `ok` on a unit whose timers never resume. Not yet filed. API-driven maintenance depends on it.
- Whether `mast-monitor` is a GUI application or a headless process with a status surface and, later, a tray applet. "Visible" and "a GUI" are not the same requirement, and the monitor is the component that must not itself fail.
- How the maintenance flag is written -- direct pymongo, or a controller API with validation and an audit trail. The API is the better shape and is awkward precisely when it is needed, since maintenance is often set because something is broken. And what the monitor should do when MongoDB is unreachable: defaulting either way is wrong, caching the last known value is probably right, and a local override is needed for "the DB is down and I need to work on this unit".
- `units_in_maintenance` is a bare `list[str]` and records no who, when or why. For a flag that stops a telescope receiving work -- and now also stops its automation being supervised -- that is thin. Cheaper to add before there are twenty units than after.
- Auto-logon remains required: `WTSQueryUserToken` fails when nobody is logged on, and the watcher cannot create a session. The stored auto-logon credential is unchanged by this design, and the watcher is LocalSystem in addition.
- Already-provisioned units carry the four existing services, so this needs a **removal** step and not only a redefinition. A leftover `mast-pwi4` set to Automatic would contend with the monitor for the same process.
- Whether the ASCOM cover path depends on `PWShutter.exe` was not tested; only that the PWI4 path does not. `PWShutter.exe` must stay in `app.py` until `covers.py` actually moves (MAST_unit#134).
