---
decided: 2026-10-18
status: accepted
issue: MAST_supervision#18
areas:
  - storage
  - providers
---

# The RAM-disk restart is a SYSTEM task that interactive users may run

**Why:** The MAST supervisor revives `D:` when the ImDisk RAM disk is lost mid-run (MAST_supervision#18; mast-claude-config `plans/filing-areas-design.md` §8.1). The supervisor runs unelevated in the autologon `mast` session. On mast00, measured on 2026-10-18, UAC is on (`EnableLUA=1`) and the boot task's ACL gives the `mast` user only `FR`. So the supervisor can neither force-detach a disk (`imdisk -D`) nor run the SYSTEM boot task.

**What:** `server/providers/imdisk/provide-imdisk.ps1` registers a second task, `mast-ramdisk-restart` (`${RestartTaskName}`), next to `MAST-ImDisk-Persistent` (`${TaskName}`). It runs as SYSTEM with no trigger. Its action is `cmd.exe /c "imdisk -D -m D: & schtasks /run /tn \MAST-ImDisk-Persistent"`, so the image is still named only in the boot task. Its DACL gains `(A;;FRFX;;;IU)`, set through the `Schedule.Service` COM object, which lets interactive users run it. The supervisor runs it with `schtasks /run /tn \mast-ramdisk-restart`.

**Implications:**

- Any interactive user on a unit can wipe `D:` by running the task. The supervisor guards against wiping a healthy disk: it probes `D:` with a write first, and does nothing if the write succeeds. The task itself has no guard.
- The task name is shared with MAST_supervision's `ramdisk.RESTART_TASK`, and the two must agree. Nothing checks that across the repos.
- The change re-runs the imdisk module on every unit through payload-hash drift. A re-run reuses the image and leaves a mounted `D:` intact.
- mast00 is not production-provisioned, and its boot task is the ImDisk Toolkit's `ImDisk Persistent Drive`, running as `mast`. Its restart task must be registered by hand, pointing at that name.

**Rejected:**

- *Grant interactive users run access on the boot task itself.* Running the boot task alone cannot detach a dead disk, and the detach needs elevation.
- *Grant the `mast` user's SID instead of `IU`.* That means resolving the SID at provisioning time. An SSH session, which is a network logon, is outside `IU` either way.

**Unsettled:**

- Not yet run on a unit. Neither the `cmd /c` quoting nor the DACL edit has been seen working. The first `provide-imdisk.ps1` run on a unit, or the by-hand registration on mast00, is the test.
