---
decided: 2026-08-17
status: proposed
issue: MAST_provisioning#87
areas:
  - transport
  - dev-harness
  - failure reporting
---

# The pull script's argument list has one owner, and the prov address is computed once

**Why:** a full dev VM cycle failed at TRANSFER with `NET_USE_ATTEMPT user=mast-transfer share=\\\mast-staging` -- the server name empty -- and `net.exe: System error 67`. The cause was six days old. `4f58726` ("Tell the unit an address on its route, not this machine's name", the #70 change recorded in `2026-08-11-the-unit-is-told-an-address-not-a-name.md`) renamed `client/mast-pull-staging.ps1`'s parameter from `-ProvServer` to `-ProvAddress`. `prov.driver._transfer` was updated. `vm/run-prov-test.py`'s `phase_transfer` was not, because it builds its own invocation.

Two things then conspired to make it silent. The script is a *simple* function -- no `[CmdletBinding()]` -- so PowerShell routed the unrecognized `-ProvServer` into `$args` rather than raising a parameter-binding error, and `$ProvAddress` came through empty. And the harness is the only caller that would notice, so fleet provisioning through the driver kept working. Every dev VM cycle had been failing at transfer since 2026-08-11 and nothing in CI, lint or the 405-case suite could see it.

**What:** deduplicate the three facts both callers had been deriving independently, rather than repair the flag name in the copy that drifted.

- **`Driver._local_address_for` + `DISCARD_PORT` move to `prov.transport.local_address_for()`.** A `@staticmethod` with no instance state, so the lift is verbatim. Its docstring already described the harness's situation -- *"also correct for a dev VM on the host-only network, which legitimately sees a different address than a production unit does"* -- so the function that fixes the harness was written thinking about the harness. The only thing keeping it out of reach was that it lived in `prov.driver` while `vm_lib` re-exports `prov.transport`.
- **`prov.transport.pull_staging_args()` is now the one place that names that script's parameters.** The two callers legitimately differ in how they *invoke* the script -- the driver by path, the harness as a scriptblock built from the file's text, because invoking the `.ps1` directly trips the unit's Restricted ExecutionPolicy -- and in how they read the result: the driver parses a `PULLRESULT` JSON marker into structured outcomes, the harness raises on a non-zero exit. So the shared thing is the argument list, not the phase. That is exactly what drifted.
- **`prov.transport.ps_lit()`** joins `_ps_escape` as the canonical PS-literal helper; `driver._ps_lit` delegates to it. A side effect worth naming: the harness previously escaped only the SMB password, so every other value went through unquoted-by-convention. All six are literals now.
- **The harness derives an address instead of passing a name.** `socket.gethostbyname(host_unit)` then `local_address_for(...)`, falling back to `PROV_SERVER` if resolution fails -- the same shape as the driver falling back to `prov_identity`. For a host-only dev VM this yields the VirtualBox host address, which is the thing the guest can actually reach.
- **`[CmdletBinding()]` on `mast-pull-staging.ps1`.** The next mismatched parameter is an error at the call, not an empty string and a `net use` failure two layers away. Nothing in the script reads `$args`, so the change is free.
- **`test_pull_staging_args_match_the_script`** parses the script's `param()` block and asserts the builder emits exactly those flags, plus that `[CmdletBinding()]` is present. It fails on `4f58726` as written.

**Rejected:**

- **Renaming `-ProvServer` to `-ProvAddress` in the harness and stopping there.** A one-word fix for the symptom that leaves two copies of the invocation, so the next parameter change breaks one caller again. The bug is the duplication; the flag name was how it surfaced.
- **Sharing the whole transfer phase.** Tempting, and wrong: the driver's version fails closed on a whitelist of outcomes and writes structured activity rows (`2026-07-19-transfer-phase-fails-closed.md`), while the harness's raises and prints for a human watching a dev cycle. Collapsing them would either drag run-log semantics into the harness or dilute the driver's fail-closed contract.
- **Leaving the harness alone because it is scheduled for retirement.** Its own docstring says it "is retired once `server/prov/driver.py` covers the dev cycle too." But it is the only way to exercise a full cycle against the dev VM today, so a broken harness means no pre-merge validation at all -- which is how this landed.
- **Keeping `_local_address_for` on `Driver` and having the harness import `prov.driver`.** Would work, and it makes the dev harness depend on the production orchestrator for a stdlib socket call. `prov.transport` is the module both already share.

**Unsettled:**

- **Nothing tests `local_address_for` from the harness's side.** Its two tests moved with it to `test_transport` and still cover the kernel-route and no-route paths, but the harness's `gethostbyname` -> `local_address_for` -> UNC chain is exercised only by a real VM run.
- **`PROV_SERVER` remains the harness's fallback and is still `COMPUTERNAME or gethostname()`** -- a name. It is now reached only when the unit's hostname does not resolve, where a name is no better, but it does mean the address-not-name rule has a name-shaped escape hatch.
- **The same duplication may exist for the other scripts the two callers both invoke** (`execute-mast-provisioning.ps1`, `run-verify-only.ps1`). Not audited in this change.
- **`[CmdletBinding()]` is on the pull script only.** The other client scripts have the same swallow-an-unknown-flag behavior and were left alone rather than swept.
