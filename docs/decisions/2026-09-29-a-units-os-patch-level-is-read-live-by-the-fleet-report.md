---
decided: 2026-09-29
status: accepted
issue: MAST_provisioning#15
areas:
  - os patching
  - drift
  - failure reporting
---

# A unit's OS patch level is read live by the fleet report, against the newest committed baseline

**Why.** Stage 1 (the record `2026-09-29-an-os-baseline-is-resolved-from-msrc-and-the-update-catalog`) produced baselines; nothing yet said where each unit stands against one, or what would stop a unit from taking it. That is the pre-flight for any first install, and it should exist before anything can install.

**What.**

- **`server/lib/mast-os-patch-probe.ps1`** prints one JSON object between marker lines: build, UBR, edition, the installed LCU and its install date, hotfixes, .NET release and `mscorlib.dll` version, pending-reboot reasons, free space on C:, `DISM /CheckHealth`, WinRE state, Secure Boot, and the lockdown's live state. It judges nothing. `server/prov/os_drift.py` holds the contract as a closed pydantic model (`OsProbe`) and the verdict (`assess`).
- **The pending-reboot check moved into `server/lib/mast-pending-reboot.ps1`** (`Get-MastPendingRebootReason`). `provide-reboot.ps1` dot-sources it via a new `repofiles` entry in `server/providers/reboot/module.json`, the same pattern `power-management` uses for `mast-firmware.ps1`. The probe dot-sources it too, so what the report calls pending and what the reboot provider acts on cannot drift apart.
- **`tools/fleet-drift-report.py` runs the probe live on every gather** (`gather_os_probe`) and renders an **OS patch level** section (`_render_os_patch`). It is informational: it does **not** change the report's exit code. With no unit patchable yet, every unit is `behind`, and a report that is red everywhere trains people to ignore it.
- **The reference is the newest committed baseline for the unit's build** (`load_baselines`), and `19044-2026-09` is committed alongside this change, as #15 intends: committing a baseline is the approval that makes it available. A declared default and per-unit pins arrive with the apply stages and replace this rule.
- **Verdict and blockers are separate.** A unit can be `behind` and also blocked: a **servicing** reboot pending (`CBS RebootPending`, `WindowsUpdate RebootRequired`), a component store DISM does not call healthy, or under `MIN_FREE_C_BYTES` (20 GiB) free. **Findings** are warnings that do not block: the lockdown missing, WinRE disabled.

**Three things the live run changed.** The first version was run against the fleet from the Mac before anything was committed, and three of its outputs were wrong:

1. **The LCU date.** The first cut used the newest "Security Update" hotfix date. That reads 2026-08-23 on mast06 and 2026-07-07 on mast04 while both still sit on 2024 LCUs, because WinRE and .NET updates are security updates too. The second cut parsed the install date `DISM /Get-Packages` prints on the `RollupFix` line, and mast00 came out as **2026-10-06**, in the future: DISM wrote `10/06/2026` for 10 June even though PowerShell's culture on that unit is `en-US` (`M/d/yyyy`). The locale DISM formats in is not one PowerShell reports, so its date text cannot be parsed reliably. The shipped probe reads the servicing store directly: the `Package_for_RollupFix~…` key under `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages` whose `CurrentState` is `112` (installed; `80` is superseded), with `InstallTimeHigh`/`InstallTimeLow` as a FILETIME. That is independent of locale and made the `/Get-Packages` call unnecessary.
2. **Pending reboot.** All nine reachable units carry `PendingFileRenameOperations`. Blocking on it would have blocked the whole fleet, and it does not hold servicing back: DISM installs over queued renames. It is now a `[note]`, and only the two servicing reasons block.
3. **Nothing else surprised**, which is itself a result: every unit's `RollupFix` version matches its UBR.

**The fleet on 2026-09-29** (9 of 10 reachable; mastw timed out): mast03, 05, 06, 07, 08 at 19044.4529 (June 2024); mast01 and mast04 at **4412** (May 2024, older than the image the others carry); mast02 at 6809 (February 2026); mast00 at 7417 (June 2026) with the lockdown **not** in place and .NET 4.8.1, consistent with Windows Update running on the non-production unit. Secure Boot is off on all nine.

**The one write.** The probe is past what an inline `-EncodedCommand` can carry through cmd.exe (`WINRM_ENCODED_CMD_MAX` in `prov.transport`), so `gather_os_probe` uploads both files over SFTP to `C:\Windows\Temp\mast-os-patch-probe-<uuid>`, runs the probe by path, and removes the folder in a `finally`. A folder it cannot remove raises rather than being ignored. That makes the report no longer strictly read-only on the unit, and the docstring and README say so.

**Rejected.**

- *Module facts* (`Write-MastModuleFacts` into `installed-manifest.json`, the BIOS power-policy route). Facts refresh only when a provisioning run touches the module. A unit deliberately not re-provisioned (mast02) would show a months-old patch level as current. The probe is live every gather. The stage-3 provider's verify can run the same probe file to record what it installed.
- *Parsing `dism /Get-Packages` dates*, above.
- *Treating any pending reboot as a blocker*, above.
- *Several small inline probes* to stay under the dispatch limit. That scatters one read across Python strings, against the repo rule that the `.ps1` is the source of truth.

**Unsettled.**

- **`mscorlib.dll` is assumed to carry the .NET CU's headline version.** On 2026-09-29 every 4.8 unit reads 4.8.4724.0 (4.8.4790.0 on mast02) against the baseline's 4.8.4806.0, which is consistent with that. Proof needs a unit that has taken KB5126046, which is stage 3's first install.
- **`MIN_FREE_C_BYTES` is a margin, not a measurement.** No unit is near it (400+ GB free); a real LCU's staging footprint is for stage 3 to measure.
- **mastw was unreachable** and is unassessed.
