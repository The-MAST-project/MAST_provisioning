---
decided: 2026-07-09
status: accepted
issue: MAST_provisioning#10
areas:
  - logging
  - transport
  - dev-harness
---

# Link-flap warnings are rate-limited and the heartbeat escalates, rather than either being silenced

**Why:** The mast04 overnight failure (2026-07-07) buried five meaningful events under hundreds
of untimestamped WinRM "connection interrupted/restored" WARNING lines, plus an ascom step that
logged an identical "still running" heartbeat every 30 s for 65 minutes. The signal (module
boundaries, EXCEPTION, RUN_END) was un-findable without grep gymnastics. Unattended means nobody
is watching live, so a hung loop has to be findable after the fact. (The related
TRANSFER_PROGRESS pct>100 / negative-ETA bug is a separate commit -- the junction-aware
bytes_total fix.)

**What:** Two logging changes, keeping the meaningful signal:

- **Link-flap warnings are captured and rate-limited, not suppressed.** The driver captures the
  PSRP robust-connection warnings for each long phase (execute via `-WarningVariable`, transfer via
  the job's Warning stream) and emits ONE timestamped `WINRM_LINK_FLAP` summary event with
  interrupted/restored/other counts, via the pure classifier `server/lib/mast-winrm-warn.ps1`
  (`Measure-WinRmFlap`). A flaky link is still visible (the counts), but as one line per phase,
  not hundreds.
- **The `vm_lib.py` heartbeat escalates instead of repeating.** The timeout is still checked every
  `HEARTBEAT_INTERVAL_S` (30 s), but the LOG cadence backs off (30 s -> up to `HEARTBEAT_MAX_GAP_S`
  120 s) and, past `HEARTBEAT_ESCALATE_S` (10 min), switches to a `[WARN]` line on a slower
  `HEARTBEAT_ESCALATE_GAP_S` (5 min) cadence -- so a genuinely stuck step stands out rather than
  scrolling identically.

**Rejected:**

- **Silencing the PSRP warnings outright.** The straightforward fix, and the one considered
  first; rejected per Eli. A flaky link is a real diagnostic signal about a unit's network, and
  the mast04 log was evidence of that even while being unreadable. Suppression would have made
  the log clean and the fleet less observable -- rate-limiting keeps the fact and drops the
  volume.
- **Suppressing the heartbeat after N repeats.** Same shape, same rejection: a step that is still
  running after an hour is exactly the thing an unattended run needs to surface. Backing off the
  cadence and escalating the level keeps it present and makes it louder the longer it lasts,
  which is the opposite of decaying to silence.
- **Timestamping and deduplicating the warnings in place**, leaving hundreds of lines but making
  them greppable. Not enough: the count is the information, and hundreds of deduplicated lines
  still crowd out the five events that matter.
- **Treating this as a fix for hangs.** Explicitly kept separate -- a rate-limited heartbeat makes
  a hang *visible*, it does not bound it. Hard phase timeouts stayed with the detached-execute
  work under #7, so neither item could be mistaken for having solved the other.

**Unsettled:**

- **Capturing native PSRP transport warnings is best-effort.** `-WarningVariable` and the job
  Warning stream are the channels PowerShell uses today; if a future version writes them
  elsewhere, the `WINRM_LINK_FLAP` counts read low -- and read low *silently*, which is the same
  failure shape the change is meant to remove.
- **It cannot be tested where it matters.** A flaky link does not reproduce on the stable bench
  VM, so the classifier is unit-tested against captured strings and the end-to-end behavior
  carries real-run acceptance only.
- **The escalation thresholds are guesses.** 10 minutes to escalate and a 5-minute escalated
  cadence were picked to fit the observed 65-minute ascom case, not derived from how long modules
  legitimately take. A module whose normal runtime exceeds the threshold will warn routinely.

**Implications:** This is the log-noise item 4 of `MAST_provisioning#10`; hard phase timeouts
remain item 6 (#7). Pure classifiers are covered by `server/tests/mast-winrm-warn.Tests.ps1` and
the heartbeat by `vm/tests/test_vm_lib.py::test_run_with_heartbeat_escalates_and_rate_limits`.
