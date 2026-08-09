---
decided: 2026-07-09
status: accepted
issue: MAST_provisioning#10
areas:
  - proxy
  - operator tooling
  - providers
---

# The operator proxy tool and the proxy provider share one implementation

**Why:** Units must end provisioning on the Weizmann proxy, but the state is fragile (three
surfaces -- machine env, WinINet, WinHTTP) and an on-site operator arriving with a bench-provisioned
(`-ProxyMode direct`) unit needs to flip it to Weizmann and confirm it took, with no controller /
WinRM / staging. Re-implementing the surface logic in a second script would drift from the
`proxy` provider.

**What:** Factored all proxy-surface logic out of `provide-proxy.ps1` into
`server/providers/proxy/proxy-lib.ps1` (verbatim function bodies + a `Set-MastProxyState` /
`Get-MastProxyPosture` orchestration and a pluggable logger). The provider now dot-sources the lib
and routes its output into the provisioning log; behavior is unchanged (its verification readback
still guards the set). A new `set-proxy.ps1` -- an interactive Show / Set Weizmann / Set Direct /
Re-verify tool that self-elevates and probes bcproxy:8080 vs github:443 -- consumes the SAME lib.
`provide-proxy.ps1` copies both scripts to `C:\ProgramData\MAST\proxy\` and the `desktop-shortcuts`
provider adds a "MAST Proxy" shortcut under Desktop\MAST\Operations, mirroring the
`instrument-profiles` -> `calibrate-instruments.ps1` launcher pattern. Pure helpers covered by
`server/tests/proxy-lib.Tests.ps1`.

**Rejected:**

- **A standalone operator script with its own copy of the surface logic.** The obvious cheap
  path, and the reason the item was worth a decision at all: three surfaces written two ways
  drift, and the drift shows up as an operator tool that reports success on a posture the
  provider would call dirty. Extraction was chosen precisely to make that impossible.
- **Putting `proxy-lib.ps1` in `server/lib/` with the other shared libraries.** Rejected on a
  deployment constraint rather than a taste one: `server/lib` stays on the prov server, and the
  lib has to travel to the unit alongside `set-proxy.ps1` for an operator working with no
  controller. It lives in the provider directory so the provider's existing staging carries it.
- **Rewriting the extracted function bodies while moving them.** Deliberately not done -- the
  bodies moved verbatim so the extraction is reviewable as a move, and any behavior change would
  be a separate, visible commit. The provider's verification readback was kept for the same
  reason.
- **Having the operator tool assert posture and fail**, mirroring the direct-run guard added the
  same day. Rejected: the tool is interactive and its user is standing at the machine, so
  reporting is enough; the guard's job is to catch what nobody is watching.

**Unsettled:**

- **Whether an operator will actually find and use it.** The tool is a desktop shortcut under
  Desktop\MAST\Operations, following the `calibrate-instruments.ps1` pattern, but that pattern's
  own discoverability has never been checked with an operator who did not build it.
- **The self-elevation path is only proven on the bench VM.** A unit with different UAC policy or
  a non-interactive logon was not tested.
- **`astrometry-dependencies` still hardcodes the bcproxy host**, so the "one implementation"
  claim holds for the provider and the operator tool but not for every consumer of the value in
  the repo. That third copy was left for a later pass.

**Implications:** One proxy implementation shared by the provider and the operator tool -- no
drifting second copy. This is the operator proxy-tool item from `MAST_provisioning#8`, folded into
the v3 batch; it complements (does not replace) the direct-run proxy-posture guard added the same
day, whose weizmann-run warning is the "assert Weizmann" pairing that item mentioned.
