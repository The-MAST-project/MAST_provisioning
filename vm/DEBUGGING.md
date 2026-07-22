# vm/ debugging quick reference

For ad-hoc, throwaway scripts that poke at a unit over WinRM (check logs, run
a one-off PS snippet, push a patched source file, watch a service, etc.) --
use this pattern, not a fresh `winrm.Session(...)` call.

## Rules

1. **Never instantiate `winrm.Session` directly.** Use `vm_lib.winrm_session(...)`.
   This is enforced by `MAST_provisioning/CLAUDE.md` (DRY) and keeps timeouts,
   transport, and auth consistent with the canonical orchestrator.
2. **Read credentials via `vm_lib.load_creds()`.** Do not re-implement the
   `vault/creds.json` read inline.
3. **Name throwaway scripts `debug_*.py`.** That convention makes them easy to
   spot, easy to sweep, and visually distinct from real tooling in `vm/`.
4. **Do not commit `debug_*.py`.** When you finish debugging, either delete the
   script, or -- if it captured something genuinely reusable -- promote that
   logic into `vm_lib.py` and submit it as a real change.

## Minimal template

```python
# vm/debug_check_service.py  -- throwaway
from vm_lib import load_creds, winrm_session, run_ps, check_rc

creds = load_creds()
s = winrm_session("mast-wis-01", creds["unit"])
r = run_ps(s, "Get-Service mast-unit | Select-Object Status,Name", label="svc")
check_rc(r, "svc")
```

Run it from `vm/`:

```
cd MAST_provisioning\vm
python debug_check_service.py
```

`run_ps` already prints stdout and decodes CLIXML stderr through the same
formatter the main orchestrator uses, so you do not need to handle that.

## Pushing a patched source file onto a unit

Use `upload_file_b64` -- base64-chunked, so it avoids the PowerShell quoting
problems that come from pasting raw source files into `run_ps`:

```python
from pathlib import Path
from vm_lib import load_creds, winrm_session, upload_file_b64

creds = load_creds()
s = winrm_session("mast-wis-01", creds["unit"])

src = Path("../../MAST_common/utils.py").read_text(encoding="utf-8")
upload_file_b64(
    s,
    remote_path=r"C:\MAST\repos\MAST_unit.2024-12-12\src\common\utils.py",
    content=src,
    label="utils.py",
)
```

## What `vm_lib` provides

| Symbol | Purpose |
|--------|---------|
| `load_creds()` | Read `vault/creds.json`. Raises `RuntimeError` if missing. |
| `winrm_session(host, cred, ...)` | Canonical pywinrm Session factory. |
| `wait_for_winrm(host, cred, timeout=...)` | Block until WinRM is reachable and Basic auth succeeds. |
| `run_ps(session, script, *, label, timeout_s, echo)` | Run PS with heartbeat logging, hard timeout, stderr formatting. |
| `check_rc(r, phase)` | Raise if `r.status_code != 0`. |
| `upload_file_b64(session, remote_path, content, label)` | Base64-chunked text upload. |
| `_ps_escape(s)` | Escape a value for a PS single-quoted string. |

If you find yourself wanting a helper that is not here but feels generic
(e.g. tail-a-remote-file, restart-a-service, fetch-Windows-event-log) --
add it to `vm_lib.py` rather than inlining it in your debug script.

## Known quirk: the dev VM's SSH drops out under heavy provisioning IO

On the VirtualBox dev VM (`mast-unit` / `mast-wis-01`, host-only
`192.168.56.113`), the SSH control channel goes **unreachable for a window
during heavy disk/CPU load and then recovers on its own** when the load eases.
Observed repeatedly (2026-07-21/22): a drop during the transfer phase's
multi-GB `robocopy` SMB pull, and again during the `cygwin` provider's
extract + `robocopy /MIR`. Symptoms while it is happening:

- `run_ps` stops receiving output/exit-status; the harness heartbeat logs
  `... still running` with no progress.
- A fresh TCP connect to `:22` from the host fails with `WinError 10060`
  (timed out), even though **ICMP ping to the VM still succeeds, the VBox
  host-only adapter is Up, `VMState=running`, the guest desktop is
  responsive, and the `sshd` service is running** the whole time. So it is
  not the network, not a crash, and not `sshd` dying -- the VM's SSH just
  stops servicing connections transiently under load and comes back.

**This is a dev-VM resource limitation, not a code bug**, and almost
certainly specific to the constrained VirtualBox guest (8 GB RAM, sharing the
host disk) doing large IO while also servicing SSH. The physical units have
real resources and are not expected to hit it (but worth a glance if a real
unit ever shows the same signature under a full provision).

**Mitigation in the transport (not a fix for the VM):**
`prov.transport.SshSession` sets an SSH **keepalive** (`SSH_KEEPALIVE_S`) so a
silent/half-open drop is detected in ~30 s instead of spinning to the command
timeout, and `run_ps` surfaces a dead channel as `ConnectionError`.
`_resilient_run_ps` then **reconnects and re-runs** the (idempotent) command;
`SshSession.reconnect()` is *patient* -- it polls for `:22` to come back with a
gently increasing backoff (short probes first, so it recovers almost as soon as
the channel returns) for up to `SSH_RECONNECT_MAX_WAIT_S`. `TimeoutError` (a
genuinely stuck, still-connected command) is deliberately **not** retried.

If a run still fails here, it means the unreachable window outlasted
`SSH_RECONNECT_MAX_WAIT_S` -- re-run once the VM is idle, or bump that constant.

### Distinct but related: the *host* (labcomp2) sleeping mid-run

A separate, longer outage is labcomp2 itself sleeping. It is set to never sleep
on AC, but **unplugged it will follow its battery idle-sleep timer** -- on
2026-07-22 it slept during execute and the run failed (a powered-down host
outlasts any reconnect window, and the SSH keepalive/patient-reconnect above
cannot help when the whole host is down). `run-prov-test.py` now **brackets the
whole run in a no-sleep directive** (`_keep_awake()` -> `SetThreadExecutionState`
`ES_CONTINUOUS | ES_SYSTEM_REQUIRED`): process-scoped (auto-released on
exit/crash), holds the system awake regardless of AC/battery, and does not touch
global power settings. So an unplugged labcomp2 no longer naps mid-run. It does
not override a lid-close or a critical-battery hibernate, so keep the machine
plugged in for long runs anyway.
