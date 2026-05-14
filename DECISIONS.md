# MAST Provisioning — Architecture Decisions

---

## [2026-05-14] Stage module disabled in default build

**Why:** The stage (XILab/Standa mount controller) provisioning step caused
`provisioning-execute.log` to truncate on the 2026-05-13 test run -- the log had no
SUCCESS/FAIL outcome for the module and the downstream verify/smoke files were never
written. Blocking the rest of the provisioning flow (planewave, zwo, vscode, mast, etc.)
on an unresolved stage installer problem is not acceptable while other work continues.

**What:** Commented out `'stage'` in the default `${Modules}` list in
`build\build-mast.ps1`. The module manifest, provider scripts, and assets remain intact.
Re-enable by un-commenting the line when the root cause of the log truncation is
diagnosed and fixed.

**Implications:** Builds produced until stage is re-enabled will not install XILab or
the Standa driver. Units that require mount control must have stage re-added before
production provisioning.

## [2026-05-13] SMB transfer refined: setup-smb-share.ps1, DRY transfer script, dev/prod parity

Supersedes parts of the earlier [2026-05-13] SMB pull entry below.

**Why:** Four problems were identified after the initial SMB implementation:
1. SMB share setup was baked into `build-mast.ps1`, which requires `-HostName` and is run
   per-unit. Share setup is a one-time server-level operation with no hostname dependency.
2. `-SkipSmbShare` was a workaround for the above; it spread across four call sites and
   added flag-management debt.
3. `run-prov-test.py` was using an embedded Python HTTP server for transfer -- a completely
   different mechanism from `check-and-provision.ps1`. Dev cycles were not exercising the
   real transfer code path.
4. The net use + robocopy PS block existed verbatim in both `check-and-provision.ps1` and
   `run-prov-test.py` (once as an inline ScriptBlock, once as a Python f-string). Two
   copies will diverge.

**What:**
- `server/setup-smb-share.ps1` (new): standalone elevated script that creates the
  `mast-staging` SMB share, the `mast-transfer` local account, and the NTFS ACL.
  Takes no hostname argument. Run once per provisioning server.
- `build-mast.ps1`: SMB share creation section removed entirely. `-SkipSmbShare`
  parameter removed. Callers (`check-and-provision.ps1`, `run-prov-test.py`,
  `run-verify-only.ps1` usage docs) updated accordingly.
- `run-prov-test.py`: HTTP server + `WebClient.DownloadFile` transfer replaced with
  the same SMB pull mechanism used by `check-and-provision.ps1` (net use + robocopy,
  per-run `C:\mast-staging\run-<timestamp>` staging path).
- `client/mast-pull-staging.ps1` (new): single canonical PS script containing the
  net use + robocopy + cleanup logic. `check-and-provision.ps1` sends it to the unit
  via `Invoke-Command -FilePath` (reuses existing session). `run-prov-test.py` reads
  the file and wraps it in a scriptblock call via pywinrm -- no PS logic in Python.

**Implications:**
- SMB share setup is now a documented one-time step (`.\server\setup-smb-share.ps1`)
  separate from the provisioning loop. `build-mast.ps1` can run non-elevated at any time.
- Any future change to the transfer logic (retry count, flags, cleanup policy) is made
  in one file (`client/mast-pull-staging.ps1`) and takes effect for both the autonomous
  loop and the dev harness on the next run -- no synchronisation needed.
- `vault/creds.json` must have an `smb` block for both scripts; both validate this at
  startup.

---

## [2026-05-13] File transfer switched from WinRM Copy-Item to SMB pull

**Why:** `Copy-Item -ToSession` (WinRM push) requires elevated WinRM client configuration
(`TrustedHosts`, machine-wide `Enable-PSRemoting`) on the provisioning server. That is a
blocker for running `check-and-provision.ps1` as a non-elevated service account, which is
the target steady-state. SMB pull inverts the direction: the unit reaches out to
`\\prov-server\mast-staging` and robocopy's its own payload, triggered by a short
`Invoke-Command`. No elevated server-side configuration needed for ongoing operation.

**What:**
- `build-mast.ps1` SMB share section replaced: now creates a dedicated read-only local
  account `mast-transfer` (password in `vault/creds.json` under `smb.pass`) and grants it
  `ReadAccess` at the SMB share level plus `ReadAndExecute` at the NTFS level. The
  previous `Everyone: ReadAndExecute` NTFS grant is removed (staging contains GitHub
  tokens and NoMachine licenses).
- `vault/creds.json` (and the `.template`) gains an `smb` block: `{user, pass}` for the
  provisioning-server-side transfer account.
- `check-and-provision.ps1` transfer block (was ~46 lines of per-file `Copy-Item` retry
  loop) replaced by a single `Invoke-Command` ScriptBlock that runs on the unit:
    1. `net use \\provserver\mast-staging <pass> /user:mast-transfer /persistent:no`
       (with a stale-connection cleanup before mount and one retry on failure)
    2. `robocopy <UNC-src> C:\mast-staging\<RunId> /E /R:3 /W:5 /NP /NFL /NDL`
    3. `net use ... /delete /yes` in a `finally` block
  Exit codes: robocopy rc 0-7 = OK (0=no change, 1=copied, 2-7=warnings); rc >= 8 =
  `TRANSFER_FAIL`. `TRANSFER_START`/`TRANSFER_OK`/`TRANSFER_FAIL` events are logged with
  `src_unc`, `dst_local`, `robocopy_rc`, and `note` fields.
- SMB share creation is a **one-time elevated setup** (run `build-mast.ps1` without
  `-SkipSmbShare` once). The autonomous loop keeps passing `-SkipSmbShare $true` to
  `build-mast.ps1` for the build step -- it never recreates the share.

**Implications:**
- The provisioning server needs TCP 445 (SMB) reachable from the unit subnet. On the
  host-only VirtualBox network this is already open; on physical networks a firewall rule
  may be needed.
- `mast-transfer` credentials travel over the WinRM channel (HTTP 5985 = cleartext in
  dev/test). Exposure is bounded: the account is read-only and separate from the unit
  admin account. Adopting WinRM HTTPS (`-WinRMUseSSL`) encrypts this end-to-end.
- The per-file retry loop is gone. Robocopy's `/R:3 /W:5` handles per-file transient
  failures; the stale-connection guard handles the session-level failure mode that
  previously required AV-lock workarounds.
- Operators onboarding a new provisioning server must run the elevated setup once and
  set a site-specific password in `vault/creds.json` (`smb.pass`).

---

## [2026-05-07] Re-hosted on Windows 11 host with VirtualBox + collapsed prov-server VM

**Why:** The development setup moved from a Mac (Apple Silicon) host running two
UTM VMs to a single Windows 11 machine with VirtualBox 7.2 and a single
provisionee VM. The Windows host itself is now the provisioning server -- there is
no longer a separate "prov server VM". This matches the eventual physical-fleet
topology (one dedicated provisioning machine driving N units) while removing
two layers of indirection (Mac shared folder, prov-server VM).

**What:**
- The Windows host (`192.168.56.1` on the existing VirtualBox host-only network)
  runs `build-mast.ps1` natively. No `\\vboxsvr\mast-prov` mount, no UTM SMB share.
- One VirtualBox VM (`mast-unit`, identified by hostname `mast01` / DHCP on host-only) plays the unit role. Reset
  between cycles with `VBoxManage snapshot restore` (UTM Disposable Mode is gone).
- The Mac/UTM-specific orchestrator code in `run-prov-test.py` was replaced
  with a Windows + `VBoxManage` variant. The build phase becomes a local
  PowerShell subprocess on the host (no WinRM into a prov-server VM).
- File transfer host -> unit uses HTTP pull (the throwaway orchestrator) and
  WinRM `Copy-Item -ToSession` (the autonomous `check-and-provision.ps1`),
  avoiding SMB credential setup on every unit.
- Autonomous pipeline pieces from `autonomous-provisioning.md` were built in
  parallel with the Windows port:
    - `build-mast.ps1` now emits `staging\<host>\01-provisioning\build-manifest.json`
      with a `payload_hash` (SHA-256 over every staged file).
    - `execute-mast-provisioning.ps1` writes `C:\ProgramData\MAST\installed-manifest.json`
      on a fully-clean run.
    - `server\check-and-provision.ps1` is the autonomous driver (runs as a
      Task Scheduler job via `server\install-scheduled-task.ps1`).
    - `client\onboard-mast-unit.ps1` is the one-shot bootstrap for new units.
- A new `build-autounattend-iso.ps1` produces a small companion ISO with
  `Autounattend.xml` + `bootstrap-winrm.ps1`, driving an unattended Windows
  install on fresh units (VM or physical).
- Mac/UTM-specific assets (UTM bundle template, qcow2 seed disk, EFI vars) were
  removed outright; the design is git-recoverable if ever needed again.

**Implications:**
- The `run-prov-test.py` orchestrator is now throwaway scaffolding kept only
  until the autonomous loop is verified end-to-end on a real VM. Once that
  passes it is removed.
- Physical-unit deployment uses `client\onboard-mast-unit.ps1` only -- no
  separate prov-server VM, no UTM, no Mac.
- The two-VM architecture decision below ([2026-05-04]) is partially reversed:
  the prov server is now a host machine, not a VM.

---

## [2026-05-05] Migrated dev/test environment from VirtualBox to UTM

**Why:** Apple Silicon; VirtualBox on Apple Silicon has limited ARM64 guest support and requires
VirtualBox Guest Additions for shared folder functionality — an additional install step that must
be repeated after Guest Additions updates. UTM runs ARM64 Windows guests natively with better
performance. Critically, UTM's Disposable Mode eliminates the need for explicit `VBoxManage snapshot
restore` commands: the IoT unit VM resets to its clean baseline automatically on every shutdown,
making the test loop (provision → verify → reset → repeat) fully scriptable from the Mac.

**What:**
- UTM **Shared Network** (`192.168.64.0/24`) replaces VirtualBox host-only (`192.168.56.0/24`).
  The Mac host is always `192.168.64.1`; VMs use static IPs `.10` (prov) and `.20` (unit).
- macOS **File Sharing (SMB)** of `~/shared-utm` replaces the VirtualBox Shared Folder
  (`\\vboxsvr\mast-prov`). The prov server mounts `\\192.168.64.1\shared-utm` as `Z:`.
- UTM **Disposable Mode** on the IoT VM replaces `VBoxManage snapshot restore`. Every shutdown
  discards changes; every boot restores the `post-prepare` baseline automatically.
- `run-prov-test.py` is the new Mac-side orchestrator. It drives build → transfer → execute →
  verify → reset cycles via WinRM (`pywinrm`) and UTM VM lifecycle via `utmctl`.

**Implications:**
- No `VBoxManage` commands or VirtualBox Guest Additions needed.
- The two-VM architecture, WinRM-based remote execution, and module manifest design are unchanged.
- The `utmctl` binary is at `/Applications/UTM.app/Contents/MacOS/utmctl`. If UTM is not installed
  at the standard path, pass `--utm-unit-vm` and ensure `utmctl` is on `PATH`.
- `vault/utm-creds.json` stores WinRM and SMB credentials (gitignored). See README for format.

---

## [2026-05-04] Windows 11 ARM64 (retail ISO) for provisioning server VM

**Why:** The Mac host is Apple Silicon. VirtualBox on Apple Silicon runs ARM guests natively; x64
guests require slow emulation. Microsoft's Evaluation Center does not publish an ARM64 eval ISO —
only x64. The standard consumer ARM64 download at
https://www.microsoft.com/en-us/software-download/windows11arm64 is the only readily available
ARM64 image. Windows runs fully without activation (PowerShell, SMB, WinRM unaffected); only
cosmetic restrictions apply.

**What:** The provisioning server VM uses the ARM64 retail ISO, run unactivated.

**Implications:** No licence cost or renewal needed for the dev/test provisioning server. If a
physical provisioning server is later used, it will be activated normally and this decision becomes
moot.

---

## [2026-05-04] Two-VM provisioning architecture for VirtualBox dev/test

**Why:** The build script (`build-mast.ps1`) is written for Windows — it uses PowerShell, SMB shares,
`mklink`, and `robocopy`. The host machine is a Mac (Apple Silicon), so the build cannot run natively
on the host. A single Windows IoT target VM cannot safely act as its own provisioning server because
the build mutates the filesystem and could pollute a clean baseline.

**What:** Two separate VirtualBox VMs are used:
- **Provisioning server** (`mast-prov-server`): standard Windows 10/11, runs `build-mast.ps1` and
  hosts the SMB `mast-staging` share. The `MAST_provisioning/` repo is mounted into it as a
  VirtualBox Shared Folder (`\\vboxsvr\mast-prov`) so edits on the Mac are immediately visible
  without any manual sync step.
- **Target** (`mast01`): Windows IoT, receives and executes the staged payload. Kept in a clean
  VirtualBox snapshot (`clean-state`) and restored after every failed attempt.

Both VMs share a VirtualBox host-only network (`192.168.56.0/24`) for VM-to-VM communication.
Each also has a NAT adapter for internet access.

**Implications:**
- Every provisioning attempt starts from a known-good snapshot — no manual wipe needed.
- Source edits on the Mac take effect on the next `build-mast.ps1` run with zero friction.
- The provisioning server VM only needs to be created once; it is long-lived.
- This architecture mirrors the real production topology (dedicated provisioning server →
  physical unit machines), so the dev loop exercises the actual code paths.

---

## [2026-05-04] VirtualBox Shared Folder over repo copy/sync

**Why:** The alternatives (copying files into the VM via SCP, using `rsync`, or a second git clone)
all require a manual sync step after every edit. During iterative debugging this creates friction and
risks stale files silently causing failures.

**What:** The Mac's `MAST_provisioning/` directory is mounted read-only into the provisioning server
VM as a VirtualBox Shared Folder. The build script is invoked with `-Top Z:\` pointing at the mount.
Asset binaries live in the same tree, so no separate staging of large files is needed.

**Implications:**
- The VM must have VirtualBox Guest Additions installed for shared folder support.
- The mount must be re-established after VM reboots (`net use Z: \\vboxsvr\mast-prov`). This can
  be automated with a startup script or by marking the share as persistent.
- The `staging/` output directory is written locally inside the VM (or to a separate writable path),
  not back into the shared folder, to avoid permission issues.

---

## [2026-05-04] Snapshot-based reset strategy

**Why:** Windows IoT does not have a quick "factory reset" that is reliable enough for repeated test
cycles. Manual cleanup after a partial provisioning run (uninstalling Python, removing registry keys,
deleting cloned repos) is error-prone and slow.

**What:** Before the first provisioning attempt, a VirtualBox snapshot called `clean-state` is taken
of the target VM immediately after `prepare-mast-client.ps1` completes successfully (hostname set,
`mast` user created, WinRM enabled). Subsequent resets are a three-command sequence on the Mac:
```bash
VBoxManage controlvm "mast01" poweroff
VBoxManage snapshot "mast01" restore "clean-state"
VBoxManage startvm "mast01" --type gui
```

A second snapshot (`post-prepare`) is taken after WinRM is confirmed working, so the prep step can
be skipped on all subsequent reset cycles.

**Implications:**
- Snapshot restore is fast (seconds), making tight iteration loops practical.
- The snapshot must be retaken if `prepare-mast-client.ps1` is modified.
- Disk space: each snapshot stores the delta from the base disk; expect 1–3 GB per snapshot for
  a lightly-used Windows IoT image.

---

## [2026-05-04] Module manifest design (module.json)

**Why:** Hard-coding the list of modules and their install commands in `build-mast.ps1` would make
adding or removing software require edits to the orchestrator itself, increasing the risk of
regressions across unrelated modules.

**What:** Each module is self-describing via a `module.json` manifest declaring:
- `order` — deterministic execution sequence (gaps intentional for insertion)
- `command` — the exact PowerShell command to run on the target
- `commandfiles` — files to stage (scripts + binary assets)
- `verify` — optional smoke-test command written to `*-smoke.txt` on pass

The build script reads all manifests and emits `commands.json` as the single artifact consumed by
the execution engine.

**Implications:**
- New modules require no changes to `build-mast.ps1` or `execute-mast-provisioning.ps1`.
- Order gaps (10, 20, 30 ...) allow insertion without renumbering.
- Assets are flattened into the staging root, so all module scripts share the same working directory
  during execution — module scripts must use unique asset filenames to avoid collisions.
