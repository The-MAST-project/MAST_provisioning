---
decided: 2026-08-24
status: accepted
issue: MAST_provisioning#143
areas:
  - bootstrap
  - drift
  - providers
---

# Bootstrap elements declare whether they may be re-run

Stage 1 of MAST_provisioning#143. Every entry in `client/bootstrap-elements.json` now carries a `reassert:` field saying whether the element may be run again on an already-provisioned unit, and the build fails if the registry is malformed. Nothing re-runs anything yet — this is the vocabulary the later stages need, plus the registry repair the audit turned up.

**Why the registry needed repairing first.** The `id` in that file has exactly one consumer: `tools/fleet-drift-report.py:510`, which prints the ids whose `since:` exceeds a unit's stamped `bootstrap_version`. It is matched against nothing in `bootstrap.ps1` — four id strings appear in the script, all of them prose in comments, and the only structural resemblance is the coincidence that `execution-policy` looks like `Set-MastExecutionPolicy`. Registry-to-code correspondence has therefore always been human convention, and it had duly drifted: `bootstrap.ps1` has 26 labelled sections against 16 registered elements, and three of the unregistered ones were real work the report could not name.

| Section | Verdict | `since:` |
|---|---|---|
| Time zone (Israel Standard Time, auto-DST) | registered as `timezone-israel-dst` | **3** — `3e0db2d`, 2026-07-05, whose commit message says "version 3" |
| Sync system time (NTP) | registered as `ntp-clock-sync` | **1** — `4f13542`, 2026-06-14, predating bootstrap versioning (`6749c6d`, 2026-07-02) |
| Suppress Windows popup notifications | registered as `popup-notification-suppress` | **1** — `e7a44ec`, 2026-05-13 |
| OEM factory account policy | **not an element** — prints a deprecation notice for the no-op `-FactoryUser` and changes nothing | — |

The timezone gap was the one with teeth: a unit on bootstrap 1 or 2 lacks the automatic-DST assertion — the fix for machines running an hour off in summer — and the report could not say so. `since:` values are from `git log -S` across the pre-rename path (`client/bootstrap-winrm.ps1`), not from memory.

**Why four categories and not two.** The obvious split is "safe to re-run" versus "first touch only". The audit produced a third and a fourth case, and collapsing either loses something:

- **`provider`** — `execution-policy`, `ntp-clock-sync` and `bios-power-policy-check` are each already re-asserted by a provisioning provider (`execution-policy` order 10, `timesync` order 50, and `verify-power-management` since MAST_provisioning#141). Calling these "routine" would have a re-bootstrap run do the same work a provider does moments later, by a second code path that can disagree with the first. The field names the owning provider, and the build checks that provider exists — otherwise the claim is unverifiable prose and the element is quietly re-asserted by nobody.
- **`on-demand`** — `winrm-http-basic` and `openssh-from-msi` *can* run remotely, but must never run routinely. **Decided by Eli:** these are not reinstalled on a re-bootstrap run. Reinstalling the transport underneath a live session is how a healthy unit becomes an unreachable one, and MAST_provisioning#123 is the precedent — mast06 finished a "clean" bootstrap with no SSH server on it. They stay invocable because repair is the point of having them, and remote repair is genuinely possible: each transport is the other's rescue path, so sshd is fixed over WinRM and the WinRM listener over SSH, neither needing a USB stick as long as one channel is alive.

**What:**

- 19 elements (16 + the three registered above), each with `reassert:` ∈ `routine` | `provider` | `on-demand` | `console`; `provider:` names the owner where applicable. Counts: 8 routine, 3 provider, 2 on-demand, 6 console.
- `build/build-bootstrap-lib.ps1` — dot-sourceable and side-effect-free, like `build-staging-lib.ps1`, so `server/tests/build-bootstrap-lib.Tests.ps1` exercises the same implementation the build runs. `Test-MastBootstrapElementRegistry` is pure: parsed registry plus known provider names plus the version bootstrap embeds, returning findings rather than throwing, so the build reports all problems at once.
- `build-mast.ps1` calls `Assert-MastBootstrapElementRegistry` beside the two guards that already exist for the site list and the memory figure — the same doctrine, that only the build can see both halves of a two-place fact.
- **No version bump.** These registrations describe behavior units already have; bumping `current_version` would tell every unit in the fleet it had fallen behind.

**What is deliberately NOT checked yet.** Whether the registry *covers* `bootstrap.ps1`. That is the check that would have caught the three missing elements, and it cannot be written while the elements are inline sections with no ids in the code — there is nothing to compare against. It lands with the extraction that mints those ids (#143 stage 2). Asserting it now would be theatre, and worse than nothing: a guard that passes while the thing it names is unverifiable teaches a reader the coverage is checked.
