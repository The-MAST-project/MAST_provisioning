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
