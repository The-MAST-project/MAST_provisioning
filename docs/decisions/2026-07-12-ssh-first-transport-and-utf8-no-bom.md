---
decided: 2026-07-12
status: accepted
issue: MAST_provisioning#6
areas:
  - transport
  - credentials
  - platform independence
---

# SSH becomes the primary transport, and all MAST JSON is UTF-8 without a BOM

This settles the "directional (recommended, not yet committed)" paragraph in the same-day
`2026-07-12-port-server-orchestration-to-python.md`; Eli approved both, so they are now
decided rather than recommended.

**Why:** As the server orchestration becomes platform-agnostic Python, the two
Windows-flavored fragilities in the transport/data layer should go. WinRM
Basic-over-HTTP carries a large resilient-Receive retry layer (retry-against-the-same-shell,
a transient-error budget, connection-pool eviction, CLIXML stderr parsing, WSMan timeout
tuning) that exists only because WinRM's HTTP Receive model breaks under load -- roughly
200 lines of machinery that SSH's synchronous exec makes unnecessary. It ships credentials
base64 on 5985, imposes the `EncodedCommand` size ceiling that `assert_inline_dispatchable`
guards, and is the channel that fails the post-reboot Public-profile 401 -- exactly where
SSH already saves us. `SshSession` exists today *solely* because of that regression, which
means the fleet already falls back to SSH precisely when reconnect reliability counts. And
PS 5.1's UTF-8 BOM on written JSON trips every non-PowerShell reader.

**What:**

- **SSH-first transport.** `prov.transport.connect_unit` now prefers SSH (paramiko),
  with WinRM (pywinrm) as fallback (`prefer='ssh'` default). WinRM stays as the
  fallback until the detached-execute work lands -- which neutralizes WinRM's only
  real advantage (resuming a command across a network blip) -- after which the WinRM
  code retires. Recommendation and rationale recorded on #6; robustness pairing is #7.
- **UTF-8-no-BOM + LF for all MAST JSON.** The Python driver writes plain UTF-8 +
  LF and renames atomically (`os.replace`); reads stay BOM-tolerant
  (`transport.load_json_file` / `parse_json_text`) as a permanent safety net for
  existing PS-written files. Follow-up: unit-side PS writers (execute, availability)
  switch from `Out-File -Encoding UTF8` to `[IO.File]::WriteAllText` with a no-BOM
  `UTF8Encoding($false)` (5.1 has no `utf8NoBOM`).

**Rejected:**

- **Staying on WinRM and hardening it further.** The status quo, and the thing the
  resilient-Receive layer represents: each fix made the transport more elaborate without
  making it more reliable. Rejected because the layer's existence *is* the argument --
  code that exists only to work around a protocol's failure model is better deleted with
  the protocol.
- **Moving to WinRM over HTTPS on 5986** to fix the credential exposure without changing
  transports. Rejected: it addresses one of the four problems (credentials in the clear),
  leaves the Receive model, the size ceiling and the post-reboot 401 untouched, and adds a
  certificate lifecycle to the bootstrap. Better auth from Linux (Negotiate/NTLM/HTTPS)
  also needs finicky extra dependencies, against the port's no-per-platform-code rule.
- **Adopting Ansible, Chef or Puppet instead of a bespoke transport.** Previously ruled
  moot given the provider abstraction already built on top, and not reopened here -- this
  assessment was explicitly scoped to the transport layer, not to the orchestration model.
- **Replacing the SMB pull with `scp`/`sftp`** now that SFTP rides the same channel. Not
  taken as part of this decision: SMB stays the one universal transfer path. SFTP does
  replace the base64-chunk upload hack for small files, which is a narrower change.
- **Retiring WinRM immediately.** Rejected on sequencing: WinRM's resume-across-a-blip
  advantage is real until detached execute exists. Keeping it as fallback for one step
  costs a little dead code and avoids a window where neither mechanism covers a drop.

**Unsettled:**

- **Host keys are not pinned.** The transport uses `AutoAddPolicy`, which is
  trust-on-first-use and accepts a substituted host silently. Pinning is a stated
  precondition for production and was not done here.
- **OpenSSH becomes load-bearing on every unit** rather than a fallback. `bootstrap-winrm.ps1`
  already installs it, so the belief at the time was that the fleet is ready -- reasoned from
  the bootstrap script rather than audited per unit.
- **The BOM retirement is half-done.** The driver's own writes are BOM-free immediately;
  every unit-side PS writer still emits a BOM until the `[IO.File]::WriteAllText` follow-up
  lands. BOM-tolerant reads are therefore load-bearing for an unknown period, and are kept
  permanently rather than as a migration aid.
- **Whether to keep the `-ExecutionPolicy Bypass` wrapper.** `run_ps` wraps every script in
  it, which masks unit misconfiguration: mast04 and mast03 skipped the bootstrap's manual
  `Set-ExecutionPolicy` and sat at Restricted for days without any tooling noticing, while
  every bare `powershell -File` invocation silently exited 1. An SSH-first design should
  decide this deliberately; it was left open.
- **Inherited console handles can wedge an SSH channel.** A provider-style `Start-Process`
  child that detaches (the ASCOM and ZWO installers do) inherits the channel's console
  handles, so the channel does not EOF even after the process tree is gone -- the same wedge
  WinRM's execute shell had. Self-logging scripts read from a parallel session was the
  reliable pattern; the transport does not yet handle this itself.

**Implications:** The most fragile code in the repo becomes deletable once detached execute
lands. The driver's writes stop tripping non-PowerShell readers immediately. WinRM's
retirement is now a scheduled consequence rather than an open question.
