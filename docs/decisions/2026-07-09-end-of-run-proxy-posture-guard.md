---
decided: 2026-07-09
status: accepted
issue: MAST_provisioning#10
areas:
  - proxy
  - orchestration
  - failure reporting
---

# An end-of-run proxy-posture guard, instead of patching a phantom re-introduction

**Why:** #10 item 3 ("only the proxy provider may own proxy state; audit astrometry-dependencies /
chrome / vscode") was filed against a mast03 symptom (2026-07-08): a `-ProxyMode direct` run ended
with bcproxy still set, so `git fetch` in the mast module died with "Could not resolve proxy:
bcproxy". A full code audit does not support the filed root cause: no module outside the `proxy`
provider writes any proxy surface (machine `http_proxy`/`https_proxy` env, WinINet
`ProxyEnable`/`ProxyServer`, machine WinHTTP, or the WPAD/`DefaultConnectionSettings` blob). chrome
and vscode only reference bcproxy in comments (both use offline installers); astrometry-dependencies
uses bcproxy solely to drive the cygwin `setup.exe` (`setup.rc` + `--proxy`), already keys off an
explicit `-ProxyMode` (no probing), and writes `net-method=Direct` with no proxy on a direct run.
The re-introduction was also intermittent (a later mast03 run was clean), and mast03 is unreachable
until the site trip, so the exact mechanism cannot be diagnosed now. Patching the named modules
would fix a phantom.

**What:** Rather than change proxy *management* (which stays solely in the `proxy` provider), add a
READ-ONLY end-of-run assertion. After the last module, `check-and-provision.ps1` reads the unit's
proxy surfaces over WinRM and classifies them via `server/lib/mast-proxy-assert.ps1`
(`Get-ProxyDirtySurfaces`): the machine `http_proxy`/`https_proxy` env vars are **critical** (git
reads those -- a dirty one on a `-ProxyMode direct` run is a hard `UNIT_FAIL reason=proxy_dirty_on_direct`
naming the surface); WinINet / WinHTTP are **advisory** (real proxy surfaces that do not break git,
logged `PROXY_ASSERT_WARN`). A `weizmann` run warns if the unit ended with no proxy at all (units
should end on the Weizmann proxy). Pester coverage in `server/tests/mast-proxy-assert.Tests.ps1`.

**Rejected:**

- **Implementing the fix as filed** -- audit and patch `astrometry-dependencies`, `chrome` and
  `vscode`, and enforce "only the proxy provider may write proxy state" as a code change across
  them. This is what #10 item 3 asked for, and it was rejected on evidence: the audit found none
  of those three writes a proxy surface, so the change would have edited innocent code, closed the
  ticket, and left the real mechanism live. Recorded on the issue as an explicit audit finding
  rather than silently re-scoped.
- **Waiting for mast03 to come back before doing anything.** Tempting, since the mechanism is only
  diagnosable on the machine that showed it. Rejected because the unit is offline until the site
  trip and the batch gates loop activation; a guard that makes the next occurrence loud is
  available now and turns a wait into a measurement.
- **Making the guard authoritative -- clearing or correcting a dirty posture** rather than
  reporting it. Rejected deliberately: proxy management staying in one provider is the property
  worth keeping, and a second writer that "fixes" state at end of run would destroy the evidence
  of who set it, which is the entire point while the cause is unknown.
- **Treating WinINet and WinHTTP as critical too.** Rejected as over-strict for this fix: they are
  genuine proxy surfaces but do not break `git`, which is the failure actually observed. They warn
  instead, so the data accumulates without failing runs on a symptom nobody has been bitten by.

**Unsettled:**

- **The root cause is genuinely unknown.** The audit establishes what the code does *not* do; it
  does not explain how mast03 ended a direct run with bcproxy set. The leading possibilities --
  something outside provisioning writing the machine env, a stale value predating the run, or an
  operator action -- were not distinguishable with the unit offline. The guard is instrumentation
  for that open question, not an answer to it.
- **The guard's own coverage is assumed, not proven.** It reads the surfaces known at the time;
  a surface nobody enumerated would pass silently.
- **Whether the intermittency is in the fault or in the observation.** One clean later run was
  taken as evidence of intermittency, but a single clean run is weak evidence.
- **`astrometry-dependencies` carries its own hardcoded bcproxy host**, duplicating the proxy
  provider's value. Known and left alone here; DRY-ing it belongs to the operator proxy-tool
  item, not to a read-only guard.

**Implications:** The guard turns exactly the intermittent, silent re-introduction that bit mast03
into a loud, surface-naming failure that will be caught on the next direct run at the site -- without
guessing at a culprit the code does not contain. It runs after `mast` (order 2200), so it catches a
proxy set by any source. This is the proxy item of `MAST_provisioning#10`.
