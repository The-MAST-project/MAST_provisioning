---
decided: 2026-08-26
status: accepted
issue: MAST_provisioning#10
areas:
  - proxy
  - driver
  - providers
---

# The end-of-run proxy-posture guard is retired

`Driver._proxy_assert`, `prov/proxy_assert.py` and the `PROXY_ASSERT_*` events are removed. Proxy state stays owned solely by the `proxy` provider, and the shipped posture stays verified by the order-9001 `verify-proxy.ps1` re-run that the 2026-06-25 finalize decision put there.

**Supersedes** the 2026-07-09 entry "End-of-run proxy-posture guard instead of patching a phantom re-introduction".

## Why the guard existed

mast03, 2026-07-08: a `-ProxyMode direct` run ended with bcproxy still set and `git fetch` in the `mast` module died with `Could not resolve proxy: bcproxy`. A code audit found no module outside the `proxy` provider writing any proxy surface, the re-introduction was intermittent, and the unit was offline. Rather than patch a phantom, the driver gained a read-only end-of-run assertion to turn a silent re-introduction into a loud, surface-naming failure.

That was the right call for what was known then. Three things have changed since.

## Why it goes

**1. Its premise is gone: `mast-clone` no longer inherits ambient proxy state.** Since 2026-08-02 the `mast` provider delegates cloning to `tools/mast-clone.ps1`, which takes the proxy mode *explicitly* -- `-DirectHttp`, injected by `build-mast.ps1` from the build's `-ProxyMode` -- and on a direct run **clears** any inherited proxy before running git or uv:

```powershell
# Clear, do not merely skip. An HTTPS_PROXY inherited from the caller's
# environment (a machine-wide setting, a scheduled task, an outer script)
# would otherwise still be honoured by git and uv ...
$env:HTTP_PROXY = $null; $env:HTTPS_PROXY = $null
```

That comment describes the mast03 failure exactly, and defuses it at the point of use. A stale machine proxy can no longer silently break the clone, which is the only harm the guard was protecting against.

**2. It could not detect its target anyway.** The guard reads the proxy surfaces after the *whole* execute phase -- which includes **order 9000**, the unconditional finalize step (2026-06-25) that deliberately sets the Weizmann proxy on all three surfaces so a unit ships proxy-ready. Whether or not a spurious mid-run re-introduction happened, the end state is proxied either way. The 2026-07-09 entry says the guard "runs after `mast` (order 2200), so it catches a proxy set by any source"; it in fact runs after order 9000, and order 9000 *is* a source that sets one, by design, on every run. The guard cannot tell the deliberate proxy from the spurious one.

**3. Its remaining function duplicates a real verify.** The `weizmann` branch only warned when *no* proxy surface was set. Order **9001** already re-runs `verify-proxy.ps1` against the rewritten `proxy-smoke.txt` and confirms the shipped state from inside the payload -- a stronger check than an advisory driver warning.

## The cost it was imposing

Because the build guarantees the state the assertion rejects, **every `--proxy-mode direct` run was designed to end in `UNIT_FAIL`.** It had never been observed only because direct runs are bench-only and had been failing earlier in execute. Demonstrated on mast08, run `run-20260826-140515`, where all 45 module smokes passed and the run still failed:

```
EXECUTE_OK    unit=mast08 duration_s=614
SMOKE_RESULT  ... 45 modules, 0 not OK
PROXY_ASSERT_FAIL  unit=mast08  mode=direct  dirty=http_proxy=http://bcproxy.weizmann.ac.il:8080; https_proxy=...
UNIT_FAIL     unit=mast08  reason=proxy_dirty_on_direct
```

The value it failed on is what order 9000 had written moments earlier.

## What replaces it

Nothing in the driver. Deliberately: a second opinion from the driver about state the payload already owns and verifies is what created the contradiction. `--proxy-mode` keeps its build-time meaning -- how to install -- and the unit's shipped posture keeps being decided by the `proxy` provider and confirmed at 9001.

**Rejected:** an informational `PROXY_POSTURE` event that logs the final surfaces without judging them. It reads as harmless, but it re-creates the same duplicate source of truth that 9001 already owns, and an event nothing acts on is bookkeeping rather than a signal.

**Rejected:** making the assertion skip `direct` mode. That silences the false positive while leaving a guard that still cannot detect what it was written for -- the worst of both, and it would have kept the misleading 2026-07-09 rationale on the books.

## Implications

- A `direct`-mode run can now finish green. Before this, it could not.
- Units still ship on the Weizmann proxy regardless of `-ProxyMode`, unchanged from 2026-06-25. A bench unit that needs direct egress is flipped with the operator tool `set-proxy.ps1`, which is what that tool is for.
- If a stale-proxy clone failure ever recurs, it now surfaces where it happens -- `mast-clone` failing loudly inside the `mast` module -- rather than as a posture verdict two thousand orders later.
