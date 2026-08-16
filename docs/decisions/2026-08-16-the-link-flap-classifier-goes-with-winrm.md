---
decided: 2026-08-16
status: accepted
issue: MAST_provisioning#10
areas:
  - logging
  - transport
---

# The link-flap classifier is deleted rather than kept for a WinRM feature that is not coming

**Why:** `prov/winrm_flap.py` was imported by nothing. It was ported from the retired `server/lib/mast-winrm-warn.ps1` for symmetry with the rest of the PowerShell driver's pure logic, and when that driver was retired earlier today the module was kept on the reasoning that the deferred live `TRANSFER_PROGRESS` / `WINRM_LINK_FLAP` capture would eventually use it — recorded as an *Unsettled* item in `2026-08-16-the-powershell-driver-is-retired.md`.

That reasoning does not survive contact with the transport decision. WinRM is being retired in favor of SSH (`2026-07-12-ssh-first-transport-and-utf8-no-bom.md`, and `#6` closed as decided rather than as work), so the feature the module was being held for is a feature for a transport on its way out. Per Eli: keeping it is holding dead code against a future that has been decided away.

What the classifier consumed reinforces this. It parses PowerShell's PSRP robust-connection "connection interrupted / restored" warning text, which is a WinRM-specific channel: it arrives via `-WarningVariable` or a job's Warning stream on a `New-PSSession` run. Nothing in the SSH path produces those strings, and nothing in the current tree captures them at all — the capture half was in the PowerShell driver and went with it. A classifier for a message nobody emits, on a transport being removed, is not deferred work; it is a module whose only remaining function is to look like a plan.

**What:** `server/prov/winrm_flap.py` and `server/prov/tests/test_winrm_flap.py` are deleted. The pure-logic module list in `autonomous-provisioning-requirements.md` drops it.

Nothing else changes. WinRM itself is **still live** in `server/prov/transport.py` — pywinrm remains a declared runtime dependency, `_winrm_probe_once` and `wait_for_winrm` are still the fallback behind SSH-first, and `client/bootstrap-winrm.ps1` is still how a bare unit is first reached. This change removes one dead classifier, not the transport; the transport removal stays tracked on `#10` item 9.

**Rejected:**

- **Keep it until WinRM is actually removed from `transport.py`.** The position taken this morning, and the one this record reverses. It treats deletion as something to sequence after the transport work, but the module is not part of the transport: nothing imports it, so removing it cannot break the WinRM path, and leaving it means the next person to audit `prov/` finds a tested module with no callers and has to re-derive why. Deleting it now costs a `git revert` if the flap summary is ever wanted; keeping it costs that re-derivation every time.
- **Keep the classifier and repoint it at SSH link failures.** Superficially appealing — a flaky link is a real diagnostic signal, which is precisely why the 2026-07-09 record rejected silencing the warnings. But paramiko surfaces link trouble as exceptions and channel state, not as a warning stream of English strings, so nothing of the parser transfers. An SSH equivalent would share the *intent* and none of the code, and should be written against what paramiko actually reports rather than retrofitted onto a text matcher.

**Unsettled:**

- **The rate-limiting intent is now unimplemented on any transport.** The 2026-07-09 record's first half — capture link-flap warnings, emit one counted summary per phase rather than hundreds of lines — has no implementation left anywhere, and its motivating incident (the mast04 overnight log, 2026-07-07) was a real readability failure. If the SSH path turns out to have its own noise mode under a flaky link, that problem returns unsolved. Nothing observed so far says it does.
- **That record is not marked `superseded`, deliberately.** Only its link-flap half is retired. Its second half — the transport heartbeat backing off its cadence and escalating to `[WARN]` past ten minutes — is live and load-bearing, now in `prov/transport.py` (`HEARTBEAT_INTERVAL_S`, `HEARTBEAT_ESCALATE_S`, `HEARTBEAT_ESCALATE_GAP_S`) and covered by `test_transport.py`. Flipping the whole record to `superseded` would make a reader discount rationale that still describes shipped behavior, so the half-retirement is named here instead. The supersession machinery has one setting and this is the second decision in two days to need half of one; that is worth noticing about the format rather than working around again.

**Implications:**

- `prov/` has no module without a caller. That property is worth keeping, because it is what makes "nothing imports this" a usable signal during an audit rather than a known exception.
- `#10` item 9's deferred list loses the `winrm_flap` half of the live-capture item; what remains on it is the unit-side no-BOM writers and the WinRM removal itself.
