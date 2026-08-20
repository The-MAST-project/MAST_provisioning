---
decided: 2026-08-20
status: accepted
issue: MAST_provisioning#121
areas:
  - bootstrap
  - transport
  - docs-process
---

# The first-touch script is called bootstrap, not bootstrap-winrm

**Why:** the name described the script's most interesting job in 2026, and stopped being true when transport went SSH-first (`2026-07-12-ssh-first-transport-and-utf8-no-bom.md`). What the script actually does is first-touch preparation of a bare unit: the `mast` local admin, autologon, the rename, the hardware preflight, OpenSSH Server, Npcap, the execution policy, the site prompt. Enabling WinRM is one line item among those and no longer the headline.

A stale name is not merely untidy here. `bootstrap-winrm` reads as *the WinRM one*, which implies a sibling for the SSH path. There is no such sibling and never will be; the driver reaches an already-bootstrapped unit over SSH with WinRM as fallback, and both are set up by this one script.

**What:**

    client/bootstrap-winrm.ps1        -> client/bootstrap.ps1
    client/bootstrap-winrm.cmd        -> client/bootstrap.cmd
    client/bootstrap-winrm-vmtest.cmd -> client/bootstrap-vmtest.cmd

Four places resolve or parse the path rather than merely mention it, and are the ones that would have broken: `build/build-mast.ps1` reads the file twice, for the site-list and `RequiredMemoryGB` sync assertions; `tools/fleet-drift-report.py` parses `$script:BootstrapVersion` out of it; `vm/build-autounattend-iso.ps1` stages all three onto the unit ISO; and `server/prov/tests/data/fleet_report_golden.txt` asserts the warning text verbatim. Prose references -- `module.json` descriptions, comment blocks, the `throw` messages that tell an operator which script to run first -- are swept in the same pass, because a comment naming a file that does not exist is worse than no comment.

**The log file is renamed with it.** A unit now writes `C:\MAST\logs\bootstrap.log` where it wrote `bootstrap-winrm.log`, because the sweep reached the `$script:BootstrapLog` constant and the launcher's exit message together. Kept rather than pinned back: nothing reads the path -- not the driver, not a provider, not the archival glob, which takes `C:\MAST\logs\*.log` -- and a log named after a script that no longer exists is the same defect as a comment naming one. A unit bootstrapped before this keeps its old file beside the new one, which is the honest record of which script wrote what.

**Decision records keep the old name.** Ten of them mention it and none were touched. A record states what was true when the call was made, and `bootstrap-winrm.ps1` is what the file was called then; rewriting that would make the history describe a repo that never existed. This is the immutability rule in `2026-08-16-a-record-freezes-when-accepted-not-when-merged.md` applied to a rename rather than to a reversal, and the cost is real -- a `git grep bootstrap.ps1` will not find those records. Reaching them means knowing the old name, which is what this record is partly for.

**Rejected:**

- **Leaving the name and documenting the mismatch.** Cheaper, and it preserves `git log --follow` and every link into the file from outside the repo. Rejected because the misdirection is active: the name suggests an alternative transport path exists, and the people most likely to be misled are the ones reading the repo for the first time.
- **`bootstrap-unit.ps1` or `first-touch.ps1`.** More descriptive, and both invent a term the repo does not otherwise use. The codebase already says "bootstrap" everywhere -- `bootstrap-elements.json`, `bootstrap-manifest.json`, `$script:BootstrapVersion`, the `config-bootstrap` provider. The file should be named what everything else already calls it.
- **Keeping a `bootstrap-winrm.cmd` shim that forwards.** A shim on removable media is one more file for an operator to pick wrongly, and its only reader would be muscle memory.

**Unsettled:**

- **Bootstrap media in the field still carries the old filenames.** Nothing reads them from a fixed path, so an old stick keeps working -- it runs an older script, which is the normal state of a stick that has not been rebuilt. Restaging is how a unit gets the current one either way.
- **`git log --follow` across the rename** works for the `.ps1`, whose content is largely unchanged, and is less reliable for the two `.cmd` wrappers, which are short enough that similarity detection is weak.
