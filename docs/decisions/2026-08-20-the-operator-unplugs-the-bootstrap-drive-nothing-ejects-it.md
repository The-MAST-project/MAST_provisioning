---
decided: 2026-08-20
status: accepted
issue: MAST_provisioning#121
supersedes: 2026-08-19-the-bootstrap-medium-is-not-a-conflict-and-is-ejected
areas:
  - bootstrap
  - drive letters
  - operator tooling
---

# The operator unplugs the bootstrap drive; nothing ejects it

This supersedes only the **eject** half of `2026-08-19-the-bootstrap-medium-is-not-a-conflict-and-is-ejected.md`. Everything that record says about the D: verdict stands unchanged: `self` still requires removable **and** running-from, a removable D: that is not the medium in hand still fails, and the preflight still runs before the first mutation. The medium is still not a conflict. It is simply no longer dismounted.

**Why:** `mountvol <letter> /P` killed the wrapper that called it. `cmd.exe` does not read a batch file into memory -- it seeks back to a saved byte offset for each line, so pulling the volume out from under a running `bootstrap-winrm.cmd` ends the script wherever it had got to. On mast05 the log closed cleanly at the REMOVE THE BOOTSTRAP DRIVE banner, no error anywhere, and the window vanished without reaching `pause` (#107).

The superseded record had already written down why this costs nothing:

> The eject does not survive a reboot, and the notice is what does the work.

A drive left plugged in is re-enumerated on the next boot and takes its letter back whatever `mountvol` did earlier. Only a hand on the drive was ever durable. So the eject bought a visible cue -- the volume disappearing from Explorer -- and paid for it with the tail of the wrapper, including the `pause` that keeps the window open long enough to read the very banner it was reinforcing.

**What:**

- `Dismount-MastBootstrapMedia` becomes `Find-MastBootstrapMedia`. It still resolves `$PSScriptRoot` to a drive letter and still checks `DriveType 2`, setting `$script:BootstrapMediaIsRemovable` and `$script:BootstrapMediaLetter`. It no longer calls `mountvol`.
- The REMOVE THE BOOTSTRAP DRIVE banner is unchanged and still last on screen before any reboot countdown. Its D: variant no longer claims ejecting frees the letter now; it says what actually follows, which is that provisioning fails at the imdisk mount if the drive is still there.
- `bootstrap-winrm.cmd` keeps `cd /d "%SystemDrive%\"`. The reason changes rather than disappears: a `cmd.exe` sitting on the USB holds the volume open, and the operator is now being told to pull it.
- The `bootstrap-media-handling` element description in `bootstrap-elements.json` is corrected to stop claiming an eject.

**`$script:BootstrapVersion` stays at 11.** The version tracks unit-visible capabilities a bootstrapped unit might be missing, and this removes a step without changing the state a run leaves behind: a unit bootstrapped after this ends where a unit stamped 11 already is. Bumping would have told `fleet-drift-report.py` that every unit in the fleet is behind, with nothing to apply -- a false drift signal to buy a version number nobody reads.

**Rejected:**

- **Ejecting from the `.ps1` after the `.cmd` has exited.** Correct in principle and unreachable in practice: the `.cmd` outlives the `.ps1` it launched, which is the whole point of the trailing `pause`.
- **Keeping the eject and dropping the `.cmd` wrapper**, running the `.ps1` directly. That trades a working double-click entry point, an exit-code report and a window that stays open, for a cue that a reboot undoes anyway.
- **Copying bootstrap to `C:\\MAST\\bootstrap` and relaunching from there.** Still rejected, for the reasons the superseded record gives -- it re-plumbs arguments, elevation and prompts, and moves where the log and desktop report come from.
- **A `RunOnce` or scheduled task that ejects after the next boot.** Solves nothing: by then the drive has already been re-enumerated and has already taken the letter.

**Unsettled:**

- **Nothing verifies the drive was unplugged.** True before this change and true after; the imdisk provider's own D: gate remains the backstop. The difference is that the failure now surfaces at provisioning rather than being pre-empted, which is the trade taken here.
- **The banner is the only mechanism.** An operator who does not read it, or who reboots from elsewhere, gets a unit that fails its next provisioning run at the imdisk mount with a message naming D:.
