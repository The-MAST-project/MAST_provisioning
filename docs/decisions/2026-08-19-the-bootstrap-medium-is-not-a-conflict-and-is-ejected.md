---
decided: 2026-08-19
status: superseded
superseded_by: 2026-08-20-the-operator-unplugs-the-bootstrap-drive-nothing-ejects-it
issue: MAST_provisioning#104
areas:
  - bootstrap
  - drive letters
  - operator tooling
---

# The bootstrap medium is not a D: conflict, and is ejected at the end

This does **not** supersede `2026-08-19-a-unit-asserts-its-hardware-before-bootstrap-changes-anything.md`. Every claim in that record stands — the gate, its position ahead of the first mutation, the hard failure, the single declared memory figure. This answers a case it did not consider.

**Why:** the D: assertion failed on the first unit it met. On a bare unit the **bootstrap USB itself takes D:** — `C:` is the system disk, `D:` is the next free letter — so the check fired on the very medium carrying the script that was running it. The operator worked around it by copying the files to the desktop and unmounting the drive, which is exactly the manual step the check exists to stop depending on.

The check was asking the wrong question. It asked *"is D: occupied?"* when the thing that matters is *"will D: still be occupied when the imdisk provider mounts it"* — several reboots and one payload transfer later. A USB carrying the bootstrap scripts is transient by construction: the one occupant of D: guaranteed to answer no.

**What:**

- `Get-MastDriveDVerdict` takes `-RunningFromD` (the caller passes `$PSScriptRoot -like 'D:*'`) and gains two verdicts. `self` — removable **and** the medium in hand — passes with the obligation stated. `removable` — a removable D: that is *not* the medium in hand, such as a stick left mounted while bootstrap runs from a copy on `C:`, or a card reader — still fails, but with a message naming ejection as the fix rather than the old `DriveType=2 label='USB DISK'` with no hint.
- `Dismount-MastBootstrapMedia` runs at the **end** of a successful run — after the Npcap installer, which is launched from the media, and after the desktop report. It ejects the volume the script ran from when that volume is removable (`mountvol <letter> /P`, verified by the drive letter disappearing), then prints an unmissable banner telling the operator to unplug it. Every failure in it is a warning: it is a courtesy, not a precondition.
- `bootstrap-winrm.cmd` and its vmtest twin `cd /d "%SystemDrive%\"` instead of `%~dp0`. A `cmd.exe` sitting on the USB holds the volume open and the eject fails with the volume in use. Nothing needed that working directory — `mast-client-util.ps1` and the Npcap installer are both found through `$PSScriptRoot`.
- Bootstrap version 11, element `bootstrap-media-handling`.

**The eject does not survive a reboot, and the notice is what does the work.** A drive left physically plugged in is re-enumerated on the next boot and takes a letter again; `mountvol /P` holds only until the device is reattached, and a reboot reattaches it. What the eject buys is that the drive is safe to pull, that D: is free immediately, and that the volume vanishing from Explorer is a visible cue behind the message. Bootstrap frequently ends in a reboot (`-RebootAfterBootstrap` schedules one 90 seconds out), so the banner is the last thing on screen before the countdown, and the countdown line itself repeats it.

**`self` requires removable AND running-from, and the test that proved it was written to assert the opposite.** The first ordering returned `self` on `-RunningFromD` alone. A test asserting that a *fitted* disk is not excused by the script's location was written expecting `foreign`, and documenting the actual `self` made the hole plain: an operator who copies the payload onto the factory D: SSD and runs it from there is looking at the exact disk that has to come out, and would have been told everything was fine. The exemption rests on the volume going away, not on where the script sits.

**Rejected:**

- **Copying bootstrap to `C:\MAST\bootstrap` and relaunching from there** — automating the operator's manual workaround. It removes the collision entirely, but re-launching mid-run means re-plumbing the arguments, the elevation and the hostname/site prompts, and it moves where the log and the desktop report come from. A great many moving parts to avoid one `if`.
- **Reassigning the medium's drive letter with `diskpart` at preflight.** It mutates storage configuration before the "nothing has been changed on this machine" promise the preflight makes, and it would pull the path out from under the running script.
- **Ejecting at the preflight rather than the end.** The script is still reading from the medium — the Npcap installer is launched from it a thousand lines later.
- **Treating any removable D: as passing.** A card reader is removable and is *not* going anywhere; only the medium in hand is known to be leaving.

**Unsettled:**

- **A USB enclosure that reports itself fixed** (some SSD ones do) gets `foreign` and a hard failure rather than `self`. That is the safe direction and the message says what to do, but the operator would be told to remove a disk that is already removable.
- **Nothing verifies the drive was actually unplugged.** The eject is confirmed by the letter disappearing; whether a human then pulled it is unknowable at that point, and the next boot is where it would show. The imdisk provider's own D: gate remains the backstop.
- **`mountvol /P` was not exercised on a real unit before landing.** It is the documented dismount path and the failure mode is a warning, but the verification here is CI plus reasoning, not a bench run.
