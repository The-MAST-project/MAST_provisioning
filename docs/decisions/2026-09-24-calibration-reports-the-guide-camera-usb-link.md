---
decided: 2026-09-24
status: accepted
issue: MAST_provisioning#221
areas:
  - instruments
  - failure reporting
---

# Instrument calibration reports each ZWO camera's USB link, from the PnP parent chain, and does not gate on it

**Why:** a ZWO camera on a USB 2.0 path works, returns correct images, and reads a full RAW16 frame in 5.7 s instead of 0.87 s. Nothing noticed. On 2026-09-23 mast01 and mast04 had a Cypress `VID_04B4&PID_6572` USB 2.0 hub between the camera and the VIA `VID_2109` hub, so the camera landed on that hub's USB 2.0 companion (`PID_2211`) rather than its SuperSpeed face (`PID_0211`), where mast02 and mast03 have it. The measurement is on MAST_unit#264. The remedy is re-cabling, which provisioning cannot do; what it can do is make the condition visible.

**What:** `server/providers/instrument-profiles/instrument-link-lib.ps1` holds the pure verdict, `Get-MastUsbLinkVerdict`, and `Format-MastUsbChain`. `calibrate-instruments.ps1` dot-sources it, finds every present device whose instance ID starts `USB\VID_03C3&` (ZWO's vendor ID), walks `DEVPKEY_Device_Parent` up through the `USB\` nodes, and shows a *Camera USB link* block in `Show-State`, so the verdict appears in View, Dry run, Apply and the CLI alike, and logs it via `Write-CameraLinkLog`. `provide-instrument-profiles.ps1` copies the lib next to the tool under `C:\ProgramData\MAST\instrument-profiles`.

The verdict judges **only the immediate parent**, and PASS needs positive evidence of SuperSpeed: a hub whose bus-reported description matches `USB 3.x Hub`. A hub exposes its SuperSpeed and USB 2.0 faces as separate PnP devices, so the parent says which one the camera took, and a SuperSpeed hub port exists only on a SuperSpeed upstream path, so nothing above the parent changes the answer. A camera directly on an xHCI root hub (`USB\ROOT_HUB3x`) is **UNVERIFIED**: the root hub is one node serving both speeds, and on labcomp2 on 2026-09-24 its internal Intel Bluetooth adapter, a USB 2.0 device, sat directly under `ROOT_HUB30` and PASSed under the first build of this rule. Anything else FAILs, including a `ROOT_HUB20` parent, a hub with no description, and a camera whose parent could not be read. The full chain is still printed and logged for diagnosis.

**Rejected:**

- *The ZWO SDK's `IsUSB3Host`*, which is the direct answer — it must open the camera, and PHD2 or the unit service may be holding it. The parent chain needs neither.
- *The issue's first sketch: PASS on any root hub, FAIL on any `USB2.0 Hub` in the chain.* A camera straight on a USB 2.0 root port (`ROOT_HUB20`) would pass, and a USB 2.0 hub whose description does not say so would pass too. Positive evidence at the parent closes both.
- *PASS on an xHCI root port*, which the first build of this change did. It false-passes a USB 3 camera on a USB 2.0 cable into a root port, for the dual-speed reason above.
- *An allowlist of known SuperSpeed hub VID/PIDs.* Stricter, but every hardware change would need a code change; the VID/PID is logged in the chain instead, so the description match can be audited after the fact.
- *Matching the camera by the `ASI\d+` friendly name.* The vendor ID is what the device reports about itself; the friendly name comes from the driver package.
- *Gating: a non-zero CLI exit on FAIL, or withholding the `.calibrated` stamp.* Nothing reads either as a readiness signal today, so a gate would have no consumer; and the COM bindings are unrelated to the link and must not wait on a re-cabling.

**Unsettled:**

- The SuperSpeed rule rests on the VIA hub's self-reported `USB3.0 Hub` string, taken from the 2026-09-23 survey as recorded on #221 and not re-read from a unit for this change. The `ROOT_HUB30` instance-ID form and the parent walk itself were exercised on labcomp2, which has no hubs, so the hub path is covered only by the Pester fixtures.
- A root-port camera stays UNVERIFIED. The negotiated speed is readable from the hub driver's connection-information IOCTL, which was not pursued; no surveyed unit has its camera on a root port.
- `calibrate-instruments.log` is truncated at the start of every run, so the log records the last run's link, not a history. A unit that regresses after re-cabling is caught only if someone runs the tool again.
- Recording an expected per-unit verdict, so that a regression is flagged against a baseline, was proposed on #221 and deferred until something consumes it.

**Implications:** a unit on the wrong link now shows a red FAIL with the re-cabling instruction in the operator menu. Turning this into a readiness gate is a separate decision, to be made when there is a readiness check to hang it on.
