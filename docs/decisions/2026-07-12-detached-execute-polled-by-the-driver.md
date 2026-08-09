---
decided: 2026-07-12
status: accepted
issue: MAST_provisioning#7
areas:
  - transport
  - orchestration
  - credentials
  - service logon sessions
---

# Execute runs as a self-detaching unit task the driver polls, not a call the driver holds open

**Why:** The synchronous execute (run over the WinRM/SSH session, driver blocks on it)
dies if the transport session drops mid-run -- the "execute dies with its session" failure
that #6/#7 call out, and the one advantage WinRM had (resume a Receive across a blip). For
the unattended loop, execute must survive a session drop; that also unblocks WinRM retirement.

**What:** Execute now runs **detached** from the driver's session, encapsulated in one
standalone unit-side script `client/mast-run-detached.ps1` (Eli's "put the moving parts in a
script that runs standalone on the unit" steer):

- `-Register`: registers a **triggerless** scheduled task (interactive `mast`, elevated) that
  re-invokes the script `-Run`, then Starts it and returns. Triggerless = it only runs when
  Started, so it never re-fires at a later logon and re-provisions the unit.
- `-Run` (in the interactive session): reads `detached-run.json`, decrypts the SMB password
  from the DPAPI-`LocalMachine` blob, runs `execute-mast-provisioning.ps1`, and writes
  `execute-result.json` (`running` -> `done` + `exit_code`).
- The driver writes the inputs (config + blob), invokes `-Register`, then **polls
  `execute-result.json`**, reconnecting (`connect_unit`) if the session drops, bounded by the
  `EXECUTE_TIMEOUT_S` watchdog; it reads `exit_code` and deletes the task. Returns the
  (possibly reconnected) session so downstream phases use the live one.

**Credential handling:** execute needs the SMB password (it maps `Z: -> \\prov\mast-shared`).
A network-logon session (SSH/WinRM) **cannot** `cmdkey` (validated: "Credentials cannot be
saved from this logon session"), so the driver writes the pass as a **DPAPI-`LocalMachine`**
blob (machine-bound, encrypted, never plaintext; a network logon CAN LocalMachine-Protect) and
the detached runner decrypts it in the interactive session (LocalMachine decrypts from any
session on the box). No credential is passed to the detached process and none sits in
cleartext.

**Rejected:**

- **Keeping WinRM purely for its resume-across-a-blip behavior.** This is the alternative
  that made the transport decision hard, and detaching execute is what removes it: once the
  unit owns the run and the driver only polls a marker, resuming a Receive buys nothing. The
  two decisions were sequenced together for exactly this reason.
- **A triggered scheduled task** (at logon, or on a schedule). Rejected on a specific
  failure it would cause: a triggered task re-fires at some later logon and re-provisions a
  unit nobody asked to provision. Triggerless-and-Started makes "run once, when told" the
  only behavior available.
- **Passing the SMB password to the detached process** as an argument, an environment
  variable, or a file. Rejected -- all three put the credential in cleartext somewhere
  (command line, process environment, disk). The DPAPI-`LocalMachine` blob was chosen
  because it is the one mechanism a network logon can *write* and an interactive session can
  *read*, which is exactly the asymmetry this design needs.
- **`cmdkey` from the provisioning session.** Tried and measured as impossible, not assumed:
  a network-logon session refuses with "Credentials cannot be saved from this logon session."
  Recording the measurement matters because the API looks available and fails at runtime.
- **Spreading the detached logic across the driver and several unit-side snippets.** Rejected
  per Eli's steer -- the moving parts live in one standalone script that can be run and
  debugged on the unit by hand, which is what makes the mechanism inspectable when it fails
  at 03:00.

**Unsettled:**

- **Two of the three paths this exists for are unvalidated.** The **session-drop reconnect**
  and **reboot-survival** (`-AllowReboot`) paths are coded but not VM-validatable: in-place VM
  reboots do not return reachable, which is understood to be a VirtualBox harness artifact
  rather than a unit bug. Both await a real unit. What *was* validated end-to-end on the
  mast-unit VM is the happy path -- the detached task ran execute, `Z:` mapped from the
  decrypted blob, the driver polled the marker to `exit_code=0`, and smoke passed.
- **The polling watchdog bounds the wait, not the work.** `EXECUTE_TIMEOUT_S` stops the driver
  waiting; the detached task on the unit keeps running, and nothing reaps it.
- **Task cleanup depends on the driver getting that far.** The driver deletes the task after
  reading `exit_code`; a driver that dies mid-poll leaves the registered task behind.
- **`Z:` is still mapped by execute itself** from the decrypted blob. The steady-state durable
  mount (a `mast-shared-mount` provider, so `Z:` persists across reboots without provisioning)
  is a separate later item, and until it exists the drive letter's lifetime is tied to a
  provisioning run.

**Implications:** WinRM retirement can follow now that a detached task, not a live Receive,
carries execute across drops. The unattended loop gains the property it most needed: a network
blip no longer destroys an hour of work.
