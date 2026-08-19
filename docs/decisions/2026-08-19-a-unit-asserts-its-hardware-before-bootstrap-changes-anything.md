---
decided: 2026-08-19
status: accepted
issue: MAST_provisioning#99
areas:
  - bootstrap
  - storage
  - drive letters
  - failure reporting
---

# A unit asserts its hardware before bootstrap changes anything

**Why:** two facts about a MAST unit are load-bearing for provisioning and are supplied by a person with a screwdriver, not by any script: it has 64 GB of RAM, and drive letter `D:` is free. Both come from one place — `server/providers/imdisk/provide-imdisk.ps1` mounts `D:` as a RAM-backed **volatile** ImDisk (`imdisk -a -m D: -t vm -f <image>`), and that attach commits the image's full 32 GB.

Neither was checked anywhere. A machine that had not been upgraded, or still had its factory SSD on `D:`, did not fail at the point the operator was standing in front of it. It failed on the far side of an ~13.45 GB payload transfer and 250 modules of installation, either as `imdisk -a -m D: exited 3` (ENOMEM, the message `provide-imdisk.ps1` was already careful to capture) or as `D: is taken by another device`. The operator's memory was the only gate, and the memory upgrade is exactly the kind of step that gets done for three machines out of four.

**What:** the requirement is declared once and asserted at two points, and the build refuses to let the two disagree.

- **Declared** by `Get-MastRequiredMemoryGB` in `server/lib/mast-modules.psm1`, next to `Get-ConfiguredSites`, for the same reason that one lives there: no admin required, and the build can read it.
- **Asserted at bootstrap** by `Assert-MastUnitHardware` in `client/bootstrap-winrm.ps1`, as the first statement inside the main `try` — ahead of the hostname prompt, the site prompt and every mutation. A unit that fails is left exactly as it was found. It is a hard failure with no override switch; `-VmTestRun` downgrades it to a `[WARN]`, which is the only exemption and matches the mount type the dev VM already builds with (`build-mast.ps1 -ImdiskMountType file`).
- **Asserted again at provisioning time** at the top of `provide-imdisk.ps1`'s main block, gated on `${MountType} -eq 'vm'`, from the `-MinMemoryGB` value `build-mast.ps1` injects into the module command. Bootstrap is one-shot and run by hand; this is the gate that still fires on a unit bootstrapped before the check existed, or re-imaged, or missing a DIMM that has since died.
- **Kept in sync** by `Assert-BootstrapMemoryRequirementInSync` in `build/build-mast.ps1`, which reads `$script:RequiredMemoryGB` out of `bootstrap-winrm.ps1` and fails the build when it does not match `Get-MastRequiredMemoryGB`. Bootstrap runs offline on a bare unit and cannot import the module, so it must embed the number — the same constraint `$knownSites` has, resolved the same way.

The predicates themselves — `Test-MastMemoryRequirement` and `Get-MastDriveDVerdict` — are pure and live in `client/mast-client-util.ps1`, which both gates dot-source and `server/tests/mast-client-util.Tests.ps1` exercises without a Windows unit. That made `mast-client-util.ps1` a hard requirement of the payload rather than a nice-to-have: `build-mast.ps1` now throws instead of warning when it is missing, and `bootstrap-winrm.ps1` throws at the dot-source instead of failing a thousand lines later on an undefined `Disable-WindowsAutoUpdate`.

`bootstrap-winrm.ps1` moves to version 10 with a `hardware-preflight` element in `client/bootstrap-elements.json`, so `tools/fleet-drift-report.py` reports mast01-04 as bootstrapped before the check existed. The driver's inventory phase (`_inventory` in `server/prov/driver.py`) now also collects `memory_visible_bytes` and the per-bank capacities into `logs/prov/unit-inventory/<host>.json` and the `INVENTORY_OK` event: both gates run **on** a unit and report only there, so nothing else gives a cross-fleet read of what is actually fitted.

**Rejected:**

- **Thresholding on the exact installed total** (`Win32_PhysicalMemory` capacity sum). It is the honest figure — 68719476736 on a 64 GB machine, where `Win32_ComputerSystem.TotalPhysicalMemory` reads a little under 64 GiB because of the firmware reserve — but it enumerates nothing under some virtual firmware, which would have meant a second code path deciding what to do when the primary reading is absent. The visible total with a 5% allowance is one comparison and separates the only two configurations that exist by a factor of two; the per-bank capacities are kept as the diagnostic that says *which* slot is short. A half-populated 64 GB board reads ~32 GB and fails either way.
- **A new `hardware-preflight` provider** ordered ahead of `imdisk`. The constraint belongs to the module that creates it; a separate provider would put the requirement one directory away from the mount that imposes it, and would have needed its own `module.json` and README row to say so.
- **An operator override (`-AllowMemoryMismatch`) on the production path.** A check that can be waived at 2am by the person who forgot the RAM in the first place is not a check. `-VmTestRun` already names the one machine class that legitimately cannot comply.
- **Treating `D:` in use as a failure unconditionally.** Bootstrap is idempotent and is re-run on provisioned units, where `D:` is the index mount ImDisk put there. `Get-MastDriveDVerdict` returns `index` for a fixed drive labeled `mast-indexes` and only `foreign` otherwise.

**Unsettled:**

- The index volume label (`mast-indexes`) is now embedded in `bootstrap-winrm.ps1` as well as being `provide-imdisk.ps1`'s `-IndexSubdir` default, and nothing asserts the two agree — unlike the memory figure. It has never changed and is baked into the image on every provisioned unit, so the exposure is a false hard-failure when re-running bootstrap on a unit whose label was changed. Cheap to fold into `Assert-BootstrapMemoryRequirementInSync` if it ever moves.
- `-MinMemoryGB` defaults to `0` (assert nothing) so the number is not copied into the provider. `build-mast.ps1` always injects it, so every payload carries the real value, but a hand-run of `provide-imdisk.ps1` outside a build silently skips the check.
- The 5% allowance is reasoned about, not measured against a real unit's reported total. The floor it produces is 60.8 GiB, which no plausible reserve reaches; if a unit ever reports lower, the reading — not the allowance — is the thing to look at.
- Nothing uses the inventory's memory field yet. `tools/fleet-drift-report.py` is the obvious consumer (a column beside the bootstrap version), and was left out of this change.
