---
decided: 2026-08-17
status: proposed
issue: MAST_provisioning#87
areas:
  - transport
  - static analysis
  - orchestration
---

# A unit session is a union, a unit response is a protocol

**Why:** `_resilient_run_ps` in `server/prov/transport.py` declared `session: winrm.Session` and then called `session.run_ps(script, timeout_s=timeout_s)`. pywinrm's `Session.run_ps` has no `timeout_s`, and since SSH became the default transport (`2026-07-12-ssh-first-transport-and-utf8-no-bom.md`) the object that actually arrives is an `SshSession`. The annotation had been wrong for five weeks. Neither `ruff` nor the test suite could see it -- the suites exercise the SSH path, where the call is correct -- and stage 1 of #87 could only waive it (`2026-08-17-pyright-not-mypy-for-the-python-server.md`).

Two more consequences of the same wrong model: the shared run paths declared `-> winrm.Response` while returning `_SshResponse` on the SSH path, and `prov.driver` annotated all fifteen of its session parameters `Any`, which left every `session.run_ps(...)` call in the orchestrator unchecked.

**What:** `transport.UnitSession`, a union alias, plus `transport.UnitResponse`, a Protocol -- and they are deliberately different mechanisms.

**The session is a union, because that is what makes narrowing work.** `UnitSession = SshSession | winrm.Session`, and `isinstance(session, SshSession)` then narrows to `SshSession` alone. Annotate the parameter `winrm.Session` and write the same `isinstance` -- what the code did before -- and pyright instead synthesizes `<subclass of Session and SshSession>`, whose MRO puts pywinrm first: `run_ps` resolves to the signature *without* `timeout_s` and every SSH call site reads as an error. The union is not a stylistic preference over a Protocol here; a `run_ps` Protocol could not carry `timeout_s` at all, because pywinrm's real `Session` does not have it and would stop satisfying the Protocol.

Plain assignment rather than a PEP 695 `type` statement: `vm/vm_lib.py` re-exports this surface to the harness, and there is no reason to put a 3.12 syntax floor into it.

**The response is a Protocol, because the two classes are unrelated.** `winrm.Response` and the local `_SshResponse` share exactly `status_code`, `std_out`, `std_err`, and pywinrm's class cannot be made to declare a base of ours. `run_ps`, `_resilient_run_ps` and `check_rc` now name `UnitResponse`; both classes satisfy it structurally, which was verified rather than assumed. `test_unit_response_protocol_covers_both_transports` in `server/prov/tests/test_transport.py` pins it in both directions with two annotated bindings -- adding a member to the Protocol that one class lacks, or dropping one from either class, now fails the type check at review.

**And the driver's fifteen `session: Any` parameters became `transport.UnitSession`** -- `_transfer`, `_execute`, `_smoke`, `_proxy_assert`, `_inventory`, `_set_available` / `_set_unavailable`, `_reclaim_availability`, `_release_and_archive`, `_download_dir`, `_write_unit_json`, `_write_detached_inputs`, `_write_shared_cred`, `_ps_out`, `_unit_can_reach_staging`. That was the substantive win and it cost nothing: measured across four prototypes, the whole retype -- transport, driver and the `vm/` harness -- produces **zero** new findings. Before starting it looked like a dozen.

`_dispose_winrm_session(sess: UnitSession | None)` was tightened from `Any | None` in the same pass, and in the `vm/` harness `_find_unit_log_path`, `_fetch_session_log_tail`, `phase_reset`, `ExecuteLogPoller._new_session` and the cycle loop's `unit_session` lost their `Any`s too.

**Rejected:**

- **A `run_ps` Protocol for the session.** The obvious symmetric design, and it cannot express this: `SshSession.run_ps` takes `timeout_s` and pywinrm's does not, so either the Protocol omits it (and the SSH-only call at the reconnect loop stops type-checking) or includes it (and `winrm.Session` no longer conforms). The union sidesteps the question by letting the existing `isinstance` guard do the work it was already doing at runtime.
- **Deleting the WinRM branch outright.** WinRM is on its way out -- SSH-first is adopted and the `winrm.Session` fallback exists for the post-reboot Public-profile 401 -- so a union of two members will eventually be one type and both names can go. Rejected as premature: removing a fallback is a behavioral change with its own risk, and it does not belong inside a typing change. Low priority, not scheduled.
- **Keeping `Any` in the `vm/` harness.** It is dev tooling and a looser standard would be defensible, but the prototype showed the retype was free, and the harness is where a session is passed between the most functions.
- **`@runtime_checkable` on `UnitResponse`** so the new test could `isinstance`-check it. It would make the test's conformance half assert at runtime as well, and it would also invite production code to isinstance-check a Protocol that exists to be checked statically. The annotated bindings are the guard; the checker is blocking in CI, so they are enforced.
- **Removing the transient `self._session = None` in `ExecuteLogPoller._run`'s reconnect handler**, which would let the attribute be typed `SshSession` outright. It is a deliberate "do not hold a disposed session" line; the type is `SshSession | None` and `_run` returns early on None instead, which is reachable only after `stop()` -- and `stop()` joins the thread before nulling.

**Unsettled:**

- **`_clean_error_msg` is still a reach into pywinrm's internals**, now waived as `# pyright: ignore[reportPrivateUsage]` rather than mypy's `[attr-defined]`. Reimplementing pywinrm's stderr post-processing to avoid it would guarantee drift; the reach is the lesser evil while the WinRM path exists at all.
- **`_execute` still returns `tuple[bool, Any]`** -- the second element is a session, but the union is not yet threaded through the return. Nothing forced it in this change.
- **Nothing asserts that `SshSession` stays a drop-in for the members the orchestrator uses.** The new test covers the *response* contract; the session side is covered only by the union narrowing correctly at each `isinstance`, and by the SSH path being what production runs.
- **`vm_lib` re-exports `UnitSession` / `UnitResponse` via `from prov.transport import *` and `__all__`.** That resolves for the type checker today; a future move away from the star-import would need them named explicitly in the shim's second import block.
