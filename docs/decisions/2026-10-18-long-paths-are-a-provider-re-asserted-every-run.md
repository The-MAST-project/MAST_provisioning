---
decided: 2026-10-18
status: accepted
issue: MAST_provisioning#248
areas:
  - providers
  - storage
---

# Long paths are a provider, re-asserted every run

**Why:** The storage-areas plan moves the shared area from `Z:` to its UNC path, and the longest product path on mast00 grows from 238 to 263 characters, over `MAX_PATH`. `LongPathsEnabled` read 0 on mast00 (2026-10-14). Without it, the RAM-to-share mover fails on such a product and retries it forever. The setting is a prerequisite of the UNC switch and must reach the whole fleet first.

**What:** A new provider, `server/providers/long-paths`, order 30, `always: true`. `provide-long-paths.ps1` writes `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled = 1` (DWORD) when it is not already 1, and reads it back. `verify-long-paths.ps1` reads the live value. The key, name and value live once, in `mast-long-paths-lib.ps1`, which both scripts dot-source.

**Implications:**

- Windows reads the value when a process starts. A unit whose value was just flipped keeps the old limit in every process already running (the unit app, VS Code, PWI4, PHD2) until they restart. The provider does not request a reboot; it logs that a restart is needed when it changes the value.
- mast00 (excluded from fleet runs) and mast-ns-spec (not provisioned) are outside this provider's reach. They need a one-off run, or the registry write by hand, before the UNC switch.
- The verify checks the registry only. The end-to-end check, creating a ~300-character path on the share from Python, stays the manual step in the issue: it needs the share reachable and a restarted process, neither of which a provisioning verify can count on.

**Rejected:**

- *A bootstrap element.* Bootstrap runs once at first touch, so it would reach new units only. The fleet is already bootstrapped.
- *A `routine` bootstrap element re-asserted by `bootstrap-reassert`.* It would work, but a single registry value with a live verify fits the provider model directly, the way `execution-policy` does, and gets its own verify log and smoke marker.
- *Payload-hash drift alone (`always: false`).* A value changed out of band produces no drift, so nothing would look at it again.
