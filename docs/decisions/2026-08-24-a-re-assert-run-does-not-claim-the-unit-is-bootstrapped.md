---
decided: 2026-08-24
status: accepted
issue: MAST_provisioning#143
areas:
  - bootstrap
  - drift
  - transport
---

# A re-assert run applies elements without claiming the unit is bootstrapped

Stage 3 of MAST_provisioning#143. `bootstrap.ps1 -ReassertOnly [-Elements a,b,c]` re-applies the re-assertable elements on an already-provisioned unit: no prompts, no reboot, no first-touch work. This is the mode a provisioning run will invoke, so the fleet converges without anyone carrying a USB stick to a unit.

**Why it must not stamp `bootstrap_version`.** The obvious ending for a successful re-assert is to record that the unit is now at bootstrap version N. That would be false, and dangerously so. A re-assert applies the `routine` elements and, by construction, none of the `console` ones — so a unit that has never had `computer-rename` or `mast-admin-account` applied would be recorded as fully bootstrapped, and `tools/fleet-drift-report.py` would stop listing what it is missing. The report's whole value is naming the gap.

So the run writes a `reassert` block into `bootstrap-manifest.json` — when, which elements were requested, applied and failed, and the script version that did it — **beside** whatever `bootstrap_version` is already stamped, and leaves that field alone. On a unit with no manifest at all the version stays `null` rather than being invented. That case is not hypothetical: mast02 predates bootstrap stamping and is the named target of #143.

**Why an unrunnable request is an error, not a skip.** Asking for a `console` element could reasonably be ignored with a warning. It is refused instead, with a non-zero exit and nothing run at all. A quiet skip would let an operator who explicitly named an element believe it had been applied — and the elements in question are exactly the ones whose absence is invisible until a unit fails to come back. The same applies to an unknown id: a typo must not silently degrade into "applied the other three".

**Why `on-demand` needs naming.** The default set is every `routine` element. `winrm-http-basic` and `openssh-from-msi` run only when named explicitly, which is the mechanism enforcing the decision recorded in `2026-08-24-bootstrap-elements-declare-whether-they-may-be-re-run.md`: the two elements that re-assert the transport the run may be travelling over can never be swept into a routine convergence pass. Repair stays possible, and stays deliberate.

**Why the classification is embedded in the script.** `-ReassertOnly` has to know each element's kind, and bootstrap runs offline from removable media where it cannot read `client/bootstrap-elements.json`. So the dispatch map carries `Kind` alongside `Function` — the same embed-and-guard arrangement `$knownSites` and `$script:RequiredMemoryGB` already use, and guarded the same way: `Test-MastBootstrapDispatchCoverage` fails the build when an embedded `Kind` disagrees with the registry. A copy that can drift silently is worse than no copy, because a `console` element mislabelled `routine` in that copy would be re-asserted remotely — precisely what the classification forbids.

**What:**

- `-ReassertOnly` and `-Elements`. Default is the `routine` set; `-Elements` takes exactly what it names. Implies non-interactive: it returns before every prompt, the hardware preflight (which throws by design, and asserts a *free* `D:` that a provisioned unit has legitimately filled with the index volume), account creation, autologon, rename, Npcap, media handling and reboot.
- One element failing does not abandon the rest — the run continues and reports per element — but the exit code is non-zero. A partial application that reports success is worse than not running.
- The failure trailer is mode-aware: the "Public network or AllowUnencrypted" hint belongs to first touch and is noise in a re-assert.

**Verified on the dev VM** (`mast-unit`, Win11 IoT LTSC 26100): `console` and `provider` elements and unknown ids are all refused with the reason named, nothing run, exit 1.
