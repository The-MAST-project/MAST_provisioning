---
decided: 2026-08-24
status: accepted
areas:
  - firmware
  - hardware startup
  - bootstrap
  - drift
---

# The BIOS power policy is read, warned about, and never blocking

A MAST unit must power itself back on when mains returns: the DLI switch cuts and restores AC, and a unit whose BIOS is set to stay off is simply absent from the fleet until somebody drives to Neot Smadar. That has been a line in the bootstrap desktop report since June -- a manual checklist item, unverifiable after the fact, which is to say a hope. It is now measured on every bootstrap and every provisioning run, and it still cannot be fixed by software.

**Why the varstore and not the vendor API.** The units are ASUS PE2100U-C7136ES boards on AMI BIOS 1.03.00, and they do expose an ASUS WMI provider (`root\WMI:ASUSManagement`, live at `ACPI\PNP0C14\ASUSWMI_0`). `GetSetupItemList` works and returns all 127 setup questions, including `APM Configuration/Restore AC Power Loss` with its `0 = S5 State / 1 = S0 State` value map. The per-item accessors do not: `GetOptionData` returns `ErrorCode 15` for every name tried -- the display name, the menu-qualified name, six other items -- and `GetBootOrder` fails identically, while `CheckPassword` returns 0. They are stubs on this BIOS build. So the vendor interface yields the catalog and never the values.

The values live in the AMI setup varstore, readable as the UEFI variable `Setup` under `{EC87D643-EBA4-4BB5-A1E5-3F3E36B20DA9}` -- 3399 bytes on this board, via `GetFirmwareEnvironmentVariableExW` with `SeSystemEnvironmentPrivilege`. It is an opaque struct: one byte per question, no names.

**Why the offsets are measured, not derived.** A field is located by toggling it in BIOS setup and diffing the blob. On mast08 (2026-08-24), `Restore AC Power Loss` moved byte `0x0D32` from 1 to 0 and nothing else in 3399 bytes; `Power On By PCIE/PCI` moved `0x0D34`; `Power On By Ring` moved `0x0D35`. Counting the catalog would have been wrong: items 97, 98, 99 land at `0x0D32`, `0x0D34`, `0x0D35`, so the order is preserved but the spacing is not, and an adjacency guess about `0x0D33` was tested and withdrawn. Any future field needs its own toggle.

The same session established the two things the check depends on. Entering setup, changing a value, saving, changing it back and saving again returned the varstore to a byte-identical state across five save cycles -- so whole-blob equality is a stable comparison, not a noisy one. And the baseline is verified rather than presumed: the operator read `S0 State` off the screen before the first toggle, and that state's blob is byte-identical on mast01, mast03, mast04 and mast08.

**Why it never blocks.** Provisioning cannot write BIOS setup on this board, so a check that failed the run would be refusing to build a unit over a condition it has no power to remedy -- and the next boards the fleet buys have not been purchased yet, so `unknown-baseline` will be the *normal* result on new hardware, not an anomaly. A gate there would stop the fleet growing. This is the same rule `verify-diagnostics.ps1` already applies with `Add-DiagWarn`: a check whose subject provisioning cannot own is reported, never asserted.

**What:**

- **One reader, one baseline.** `server/lib/mast-firmware.ps1` is the only code that reads firmware; `server/data/firmware-baseline.json` is the only statement of what is correct. Both are shipped to the unit as `repofiles` of the power-management module, and staged beside `bootstrap.ps1` by the ISO builder, so bootstrap and the provisioning verify run the *same* code against the *same* data rather than each carrying a copy.
- **Five outcomes, and only one of them stops to ask.** `match` is a one-line OK. `field-drift` (a named power field is wrong) and `unknown-baseline` (no entry for this board and BIOS, or a varstore whose length the baseline does not describe) need attention. `blob-drift` -- the hash moved but every named field is still right -- is reported and never escalated: if every difference demanded a keystroke, operators would learn to dismiss the keystroke. `unavailable` (the dev VM, any legacy-BIOS box) says so once and moves on.
- **The bootstrap prompt is an attention-getter, not a gate.** On a needs-attention result bootstrap prints a red banner and waits for the operator to press `y` -- then continues on its own after 120 seconds. `-NonInteractive` does not prompt at all, and a host with no console keyboard is never asked. An unattended run is delayed, never stopped, and no VM cycle can hang on it.
- **The acknowledgment is recorded.** `bootstrap-manifest.json` gains a `bios_check` block carrying the status, the board and BIOS, the field values and whether a human actually acknowledged (`operator` / `timeout` / `non-interactive`). Otherwise a unit knowingly shipped with a bad power policy is indistinguishable later from one nobody ever checked.
- **The fleet view warns where the facts matrix does not.** The power-management verify writes its findings as module facts, which `installed-manifest.json` carries and `tools/fleet-drift-report.py` already gathers. The report gets a dedicated *BIOS power policy* section that emits `[WARN]` lines, rather than letting these land as rows in the module-facts matrix -- that matrix deliberately does not warn, on the grounds that a fact varying across the fleet is an observation. A unit that will not come back after a power cut is not an observation.

**Found on the way:** mast02 has both `Power On By PCIE/PCI` and `Power On By Ring` enabled where mast01/03/04/08 have both disabled -- measured, not inferred, and the first thing the new check flagged when it was run against a real unit. Its `Restore AC Power Loss` is correct. Wake sources are deliberately off across the fleet (`provide-power-management.ps1` disables WoL at the NIC for the same reason), so this wants a console visit; it is not urgent, because the OS-level WoL that provisioning disables limits what the BIOS-side enabler can actually do.

**Costs accepted:**

- **The baseline is scoped to a board and a BIOS version, and a BIOS update invalidates both the hash and every offset.** That is why an unmatched version reports `unknown-baseline` loudly instead of passing quietly -- an unverifiable BIOS and a correct one must not look alike.
- **A USB kit cut before a baseline change carries a stale copy** and will report `unknown-baseline` on hardware that is actually fine. Re-cut the kit when the baseline moves; the manifest records which baseline the medium carried, so the false alarm is diagnosable rather than mysterious.
- **Naming any further field costs a reboot at a console.** Nothing derives them.
