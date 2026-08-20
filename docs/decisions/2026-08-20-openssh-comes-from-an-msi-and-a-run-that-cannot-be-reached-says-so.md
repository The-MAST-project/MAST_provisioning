---
decided: 2026-08-20
status: accepted
issue: MAST_provisioning#123
areas:
  - bootstrap
  - transport
  - failure reporting
---

# OpenSSH comes from an MSI, and a run that leaves a unit unreachable says so

**Why:** mast06 finished bootstrap cleanly and had no SSH server. `Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'` ran for 4m33s, reported success, and `sshd` was still not registered when the next line looked for it. `ssh-agent` was registered by then and got configured; `sshd` was skipped, the `sshd_config` password-auth patch was skipped with it, and both were yellow warnings inside a loop that continued. The run exited 0.

The first symptom arrived after a reboot, which made it read as *the reboot broke SSH* rather than *bootstrap never set it up*. It cost an investigation to unpick, and the message bootstrap printed actively misled -- `(capability install failed?)` on the line after `OpenSSH.Server capability installed.`

Two separate defects, fixed separately.

**What (1): the capability is not used at all.**

`provide-openssh-server.ps1` already had the answer and bootstrap did not know about it -- it ships `OpenSSH-Win64-v10.0.0.0.msi` and installs it whenever `sshd` is missing, because *"the bundled Win32-OpenSSH MSI has neither dependency: msiexec installs"*. Bootstrap now does the same thing first, rather than as a fallback:

- `msiexec /i ... /qn /norestart`, treating exit 0 and 3010 as success, then asserting `Get-Service sshd` is non-null. msiexec returns after the service is registered, so there is no asynchronous window to wait out.
- The MSI ships on the bootstrap medium as a fifth file. `build-autounattend-iso.ps1` stages it from `server/providers/openssh-server/assets/`, the same single copy the provider uses -- a second committed copy would age independently.
- The block short-circuits when `sshd` is already registered, so a re-run on a provisioned unit does not reinstall.

**MSI-only, not capability-first-with-fallback.** Keeping the capability as the first attempt preserves the in-box Microsoft-serviced component where it works, and preserves the race where it does not -- appearing only on units whose component store is not primed, which is the worst possible distribution for a bug: rare, unpredictable, and it looks like something else. One path is worth more than the in-box component here. The cost is that the fleet's SSH server is pinned by us at v10.0.0.0 and moves when we move the asset, which is how every other binary in this repo already works.

**This is the same escape #124 made for NetFx3**, one day and one directory apart: replace a Features-on-Demand payload fetch we cannot guarantee with an offline asset we ship. It is deliberately **not** the same mechanism -- an OpenSSH FoD cab would have to be matched per build, exactly the problem #124 had to introduce `assets/sxs/<build>/` to solve. The MSI is one binary for every build, so this route has no per-build dimension at all.

**What (2): a run that fails a hard requirement stops exiting 0.**

`$script:BootstrapBlockers` collects what the run was required to establish and did not. Three sites append to it: the OpenSSH install failing or its MSI being absent, `sshd` not registered when the service loop reaches it, and `sshd_config` missing so `PasswordAuthentication yes` was never asserted. At the end, a red **BOOTSTRAP INCOMPLETE** banner lists them and `Get-MastBootstrapExitCode` returns 1.

**It reports, it does not abort.** Throwing at the first blocker would skip the Npcap install, the desktop report with the MAC addresses the DHCP reservations need, and the reboot -- leaving a stranger machine than the one in hand, and losing the other blockers that would have been found. The run finishes; it stops claiming success. The banner is placed before the reboot notice so an incomplete run is the last thing read.

`Get-MastBootstrapExitCode` lives in `mast-client-util.ps1` as a pure function and is Pester-tested, including that empty and whitespace entries are ignored: a stray `+= $null` must not fail an otherwise clean run, because a false 1 costs as much operator trust as a false 0.

**`$script:BootstrapVersion` 11 -> 12**, with element `openssh-from-msi`. This one earns the bump where the rename earlier the same day did not: it changes what a bootstrapped unit is *guaranteed* to have, so `fleet-drift-report.py` correctly flags every unit stamped 11 -- including mast06, whose SSH was repaired by hand and not by bootstrap.

**Rejected:**

- **A bounded retry on `Get-Service sshd` after the capability install.** The first design, and it waits on an operation whose completion is not ours to control. `Reboot required: CBS RebootPending` at the end of mast06's provisioning run suggests the registration was reboot-gated rather than merely slow, in which case no timeout would ever have been long enough. Kept in the issue as the fallback if the MSI route is ever rejected.
- **Aborting on the first blocker.** See above; the operator needs the desktop report and the remaining findings more than they need an early exit.
- **Bundling an OpenSSH FoD cab.** Symmetrical with #124 and worse: it reintroduces a per-build payload to keep in step with every image, to obtain a component the MSI provides build-independently.
- **Leaving `sshd_config` as a warning.** Password auth is how the driver authenticates. A unit with `sshd` running and password auth unset is unreachable in the way that matters, so it belongs with the other blockers.

**Unsettled:**

- **Not yet exercised on real hardware.** Verified by parse checks, 26 Pester cases, and reading the provider path this mirrors -- not by a bootstrap on a bare unit. mast07 is the first real test. mast06's own SSH came from a hand repair and this change does not revisit it.
- **The physical bootstrap media must be restaged** to carry the MSI. An older stick runs an older bootstrap, which is the normal state of a stick that has not been rebuilt, but it will keep using the capability and can keep losing the race.
- **`ssh-agent` is still best-effort.** The MSI registers it too, and the service loop still treats its absence as non-blocking, which is correct -- nothing in provisioning needs the agent.
- **Nothing re-asserts the blocker list across a re-run.** A unit bootstrapped at version 11 with no SSH shows up in `fleet-drift-report` via the element, not by anything on the unit recording that its bootstrap ended incomplete.
