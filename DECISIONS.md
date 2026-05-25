# MAST Provisioning - Architecture Decisions

---

## [2026-05-25] Promote imdisk to order 250 with immediate mount; add gh provider; switch astrometry smoke to a real telescope FITS

**Why:** Three small changes that interlock around the astrometry verify step.

1. The astrometry smoke now solves `C:\MAST\full-frame.fits` (8288x5644
   mast00 frame, no WCS) instead of the bundled `apod5.xyls`. The real
   solve exercises the full pipeline (image2xy + fits2fits + uniformize +
   the engine itself); the xyls smoke only proved augment-xylist's
   star-list path worked. The mast00 frame needs an index file that
   covers a ~12 arcmin field; the operational index set lives on D:
   under `D:\mast-indexes` (series 5202+5203).
2. `imdisk` (which mounts D: from `C:\MAST\Shared\MAST-15GB-indexes-5202+5203.img`)
   was at order 2300 and only mounted D: at the next reboot. With the
   astrometry smoke at order 500, D: would not be reachable yet, and the
   smoke would have to either fail or skip the solve. Moving imdisk to
   order 250 puts the mount in place before any provider that needs D:.
3. We have started using `gh` interactively for PR + issue ops on units
   (alongside `git`). Adding it as a first-class provider gets it into
   the staged set and on PATH automatically.

**What:**

- **`server/providers/imdisk/`**:
  - `module.json` order 2300 -> 250.
  - `provide-imdisk.ps1` extended: after registering the boot-time
    scheduled task, if the backing image is present AND D: is not already
    in use, immediately runs `imdisk -a -m D: -f $ImagePath` and waits
    for `D:\` to surface (up to 2s, 200ms poll). If the image is missing,
    logs an `[INFO]` and falls back on the boot task as before. The
    scheduled-task path is unchanged, so the mount stays consistent
    across reboots.
- **`server/providers/astrometry/verify-astrometry.ps1`**:
  - Smoke 2 input switched from bundled demo data to
    `C:\MAST\full-frame.fits`.
  - Index discovery walks an ordered list of candidate dirs
    (`D:\mast-indexes`, `C:\cygwin64\usr\local\astrometry\data`) and uses
    the first that actually contains `index-*.fits`. If no indexes are
    reachable the verify gracefully skips the solve, logs the reason, and
    passes on banner-only -- keeping the provider tractable when the
    `imdisk` image has not yet been staged onto the host.
  - Solve args tuned for the mast00 plate scale: `--downsample 4`,
    `--scale-units arcsecperpix --scale-low 0.05 --scale-high 0.30`
    (covers ~0.09 arcsec/pix with margin for focus/temperature drift),
    `--no-verify --no-plots`, and `-N none --new-fits none` so the
    solver only emits the small artifacts we actually inspect (`.solved`
    marker and `.wcs` header).
  - On success the smoke marker now records `revision`, `wcs_bytes`, and
    the recovered `CRVAL1/CRVAL2` so a glance at the file tells you the
    plate solved to a real sky position, not just "ran without crashing."
- **`server/providers/gh/`** (new):
  - Ships `gh_2.92.0_windows_amd64.msi`, runs `msiexec /qn /norestart`
    with a per-session MSI log, and ensures `C:\Program Files\GitHub CLI`
    is on system PATH. Verify checks the binary exists, runs
    `gh --version`, writes the standard smoke marker.
  - Order 750, between `git` (700) and `ascom` (800).

**Implications:**

- D: is now mounted during provisioning, not after the first reboot.
  Anything that depends on D: being absent during stage-2 provisioning
  (none known) would change behavior.
- The astrometry smoke is now a real plate-solve test. It needs a
  presolvable FITS at `C:\MAST\full-frame.fits` and at least one index
  file under one of the configured search paths. Both are met on a
  standard MAST unit; on a stripped-down test VM neither will be present,
  the solve will skip, and the smoke will pass on the banner check alone.
  This is intentional: the smoke degrades cleanly instead of producing
  spurious failures in test scenarios.
- New runtime dependency: `gh` is on PATH after provisioning. Code that
  shells out to `gh` (none in-repo yet) can assume it is available
  starting at order 750.

---

## [2026-05-25] Renumber providers to 100-step grid; drop install-clean-cygwin.ps1

**Why:** Provider `order` values were assigned ad-hoc as features landed
(`proxy=5, openssh-server=8, cygwin=10, python=20, git=25, ascom=30, ...`).
Two problems compounded:

1. `build/build-mast.ps1:265` emits a synthetic verify step at
   `provider.order + 1`. So `cygwin` (order 10) actually occupies slots 10
   AND 11. The astrometry split landed today at `order=11` and `order=12`,
   which collided with `cygwin`-verify and `astrometry-dependencies`-verify
   respectively. The provisioning sort would still run them in roughly the
   right sequence (ties broken by file enumeration), but two providers at
   the same numeric order is a footgun waiting for a real incident.
2. Even where no collision existed, several adjacent providers were one
   slot apart (`proxy=5, openssh=8` -> gap of 3, of which 1 is consumed
   by openssh-verify). Inserting a new provider between two of those
   required also bumping every downstream provider.

Rather than patch this incrementally we picked an absolute grid up front.

**What:**

- Every `module.json` `order` was multiplied so that, sorted by current
  position, providers sit at `100, 200, 300, ...` with `reboot` pinned at
  `9999`. Concretely:

  ```
  proxy                       5  -> 100
  openssh-server              8  -> 200
  cygwin                     10  -> 300
  astrometry-dependencies    11  -> 400
  astrometry                 12  -> 500
  python                     20  -> 600
  git                        25  -> 700
  ascom                      30  -> 800
  mongodb-client             40  -> 900
  npcap                      45  -> 1000
  wireshark                  50  -> 1100
  nssm                       60  -> 1200
  nomachine                  70  -> 1300
  phd2                       90  -> 1400
  vcredist2013               95  -> 1500
  stage                     100  -> 1600
  planewave                 110  -> 1700
  zwo                       120  -> 1800
  vscode                    130  -> 1900
  sysinternals              140  -> 2000
  chrome                    150  -> 2100
  mast                      160  -> 2200
  imdisk                    170  -> 2300
  windows-exporter-monitoring 180 -> 2400
  diagnostics               200  -> 2500
  reboot                    999  -> 9999
  ```

- `vm/test-suite.py` `BOMB_ORDER` moved `65 -> 1250` (still in the gap
  between `nssm-verify` at 1201 and `nomachine` at 1300) and the
  accompanying comment + scenario description updated.
- Stale inline references in `wireshark/provide-wireshark.ps1` (npcap
  order callout) and the prior 2026-05-25 DECISIONS entry above were
  updated to the new numbers.
- `server/providers/cygwin/install-clean-cygwin.ps1` deleted. It was a
  one-line developer recipe for re-downloading the source Cygwin set with
  `setup-x86_64.exe --download`, used originally to produce
  `cygwin64-clean.tgz`. It was never part of any provisioning command and
  the same invocation (with corrected `--root` semantics) now lives
  exemplified in the `astrometry-dependencies` provider, so the standalone
  file is now misleading dead code.

**Implications:**

- Every adjacent provider pair now has 98 free `order` slots between them
  (e.g. inserting a new step between `cygwin`=300 and
  `astrometry-dependencies`=400 picks any value in 302..399). Reboot has
  ~7400 free slots above it.
- Absolute `order` values are not stable across renumbers. Any external
  log/metric/dashboard that has hardcoded a numeric order for a specific
  module (we don't think there are any -- search turned up only the bomb
  and one in-source code comment) will need to be re-pinned.
- `commands.json` is rewritten by `build-mast.ps1` from `module.json`, so
  units pick up the new ordering automatically on the next build; no
  unit-side data migration is required.

---

## [2026-05-25] Split astrometry install into three ordered providers

**Why:** The `cygwin` provider was responsible for three logically distinct
concerns: expanding the base Cygwin tree, installing astrometry-specific
runtime packages (it was not, actually -- those were silently missing), and
expanding the prebuilt astrometry.tgz. The omission of the package install
step worked only by accident: any unit that ran setup-x86_64.exe manually
afterwards happened to pull the deps in. Worse, the astrometry binaries link
against ~35 Cygwin packages (cfitsio, wcslib, netpbm, cairo, python39 plus
the curl/krb5/ldap/sasl/X11/freetype/fontconfig closure) that
`cygwin64-clean.tgz` does not include, so a fresh-from-the-archive unit
would fail `solve-field` with `STATUS_ENTRYPOINT_NOT_FOUND` or
`child_info_fork::abort`. Bundling those DLLs inside `astrometry.tgz` was
considered but rejected: Cygwin enforces one cygwin1.dll per process tree,
and any forked helper (solve-field calls `removelines`, `uniformize`,
`fits2fits`, `image2xy`) crashes when parent and child resolve different
on-disk copies. The canonical Cygwin tool for staging additional packages
is `setup-x86_64.exe -P`, and it already runs `peflagsall`/`rebaseall` in
its postinstall, which is what makes fork() reliable in the first place.

**What:**

- **`server/providers/cygwin/`** (order 300) now only expands
  `cygwin64-clean.tgz`. The astrometry-expansion block was removed from
  `provide-cygwin.ps1` and `astrometry.tgz` was dropped from
  `commandfiles`. The asset moved to the new `astrometry/` provider.
- **`server/providers/astrometry-dependencies/`** (order 400, new) ships
  `setup-x86_64.exe` and invokes it with the top-level package list
  `cygwin,libcfitsio10,libwcs4,libnetpbm10,libcairo2,libpng16,libjpeg8,
  python39`. setup.exe resolves the transitive closure (~33 additional
  packages; see `DEPENDENCIES.md` in the same dir for the exact list,
  versions, and per-DLL mapping). After install the script drains
  `/etc/postinstall/*.sh` so peflagsall/rebaseall fire, then verifies a
  spot-check of expected DLLs landed in `C:\cygwin64\bin\`.
- **`server/providers/astrometry/`** (order 500, new) expands the existing
  prebuilt `astrometry.tgz` (with debug symbols, as originally committed)
  to `C:\cygwin64\usr\local\astrometry\` and runs two smoke tests in its
  `verify-astrometry.ps1`: (1) `solve-field.exe` with no args asserts the
  binary loads and prints `Revision <n>`; (2) a real plate solve of the
  bundled `examples/apod5.xyls` against `examples/index-4119.fits` must
  produce `apod5.solved` and a non-trivial `apod5.wcs` within 120s. The
  scale window matches the upstream README recipe (`--scale-low 30` for
  index-4119, which we widened to `0.4..1.2` degwidth to absorb the
  apod5.jpg 900x675 field size).

**Implications:**

- Provider ordering is now load-bearing. The dependency provider
  (`order: 400`) **must** run between `cygwin` and `astrometry`. The plain
  numeric ordering enforces this; nothing else does.
- Targets now need outbound HTTPS to `cygwin.itefix.net` (via
  `bcproxy.weizmann.ac.il:8080`) during provisioning, since `setup.exe`
  downloads packages on the fly. For airgapped staging we will need to
  build a local mirror snapshot and point `--site` at it; that is not
  done yet.
- `astrometry.tgz` is no longer touched by the `cygwin` provider. Anyone
  who was relying on rolling `astrometry.tgz` updates through
  `cygwin/assets/` must instead update `astrometry/assets/astrometry.tgz`.
- The verify step now genuinely exercises the solver end-to-end, not just
  loader resolution. Regressions in any dep (e.g. an incompatible
  cygcfitsio.dll ABI bump) will be caught at provision time.

---

## [2026-05-24] Merge upstream/main: monitoring assets, astrometry.tgz, imdisk filename

**Why:** The upstream The-MAST-project/MAST_provisioning `main` advanced
three commits beyond our fork point with material we needed: a windows
performance-counter repair script + windows_exporter MSI, a stripped
astrometry.tgz suitable to ship in-tree, and a refined imdisk action
pointing at the canonical pre-built indexes image. Our staged Phase 2 WIP
had a parallel `windows-exporter` provider authored against a missing MSI;
the upstream merge supplies the asset and the perf-counter repair we
needed anyway.

**What:**

- **Added `upstream` remote** pointing at
  `github.com/The-MAST-project/MAST_provisioning.git`. Origin remains the
  user's fork.
- **Merged `upstream/main` into `eli/vm-provisioning`** (merge commit on
  the branch). Conflicts in `.gitignore` and `provide-imdisk.ps1`
  resolved in the merge commit; the imdisk conflict was effectively
  reconciled by the follow-on Phase 2 reshape (see [2026-05-19] entry
  below) which already implements the file-backed mount behaviour
  upstream wanted - we only carried over upstream's authoritative
  filename `MAST-15GB-indexes-5202+5203.img`.
- **`server/providers/monitoring/` collapsed into
  `server/providers/windows-exporter-monitoring/`.** Upstream shipped a
  `monitoring` provider with a TODO-stub `provide-monitoring.ps1`, no
  `module.json`, and useful assets (windows_exporter 0.31.7 MSI +
  `fix-perf-counters.ps1`). Our staged WIP had a methodology-aligned
  `windows-exporter` provider already integrated with `mast-log.ps1`.
  Kept our provider as canonical, moved upstream's MSI and the
  perf-counter repair into our `assets/`, deleted upstream's
  `monitoring/` directory, then renamed our provider to
  `windows-exporter-monitoring` so the build-list name reads as the
  metrics-export piece (other monitoring providers may follow). The
  provider now calls `fix-perf-counters.ps1` before installing the MSI
  whenever the asset is present.
- **`fix-perf-counters.ps1` ported to MAST log conventions.** Upstream's
  script logged into `C:\ProgramData\MAST\provisioning\`. Replaced that
  with a soft-fail dot-source of `mast-log.ps1` + `Get-MastLogSessionDir`,
  falling back to `C:\MAST\logs\sessions\standalone\` when the script is
  invoked outside the provisioning pipeline. Also stripped em dashes to
  satisfy CLAUDE.md's ASCII-only rule for executable scripts.
- **`server/providers/cygwin/assets/astrometry.tgz`** is now checked in
  (upstream's "without indexes" variant). Commented out the matching
  `.gitignore` entry so the in-tree file is tracked; kept the comment as
  a reminder that the full ~30 GB version is intentionally *not* what
  lives in the repo.

**Implications:**

- The merge is the first time we have pulled from upstream since the
  branch diverged; the `upstream` remote now lives in `.git/config` and
  future fetches should re-use it (`git fetch upstream`).
- Our fork's `origin/main` is still at the pre-merge tip f9ee7ed.
  Synchronising it is a separate decision and is intentionally deferred
  - the autonomous provisioning work on `eli/vm-provisioning` has not
  been promoted to main yet.
- `windows-exporter-monitoring` and `cygwin` (with astrometry.tgz) are
  now both enabled by default. The remaining asset-acquisition gap is
  `npcap-*.exe` for the wireshark provider.
- Anything that previously referenced the legacy `windows-exporter`
  name (build configs, external docs) needs renaming. The only in-tree
  references at merge time were in `build/build-mast.ps1` and
  `DECISIONS.md`; both were updated.

---

## [2026-05-19] Phase 2 of mastw vs VM gap: new providers, imdisk reshape, Compass enablement

**Why:** Phase 1 (2026-05-18 entry below) closed the cross-cutting gaps but
deferred new-provider work, version pins, and the ImDisk reshape. The user
re-imaged the VM with Phase 1 changes and we now extend the provider set to
close the remaining GAPS.md items that do not require third-party installer
assets we have not yet acquired.

**What:**

- **openssh-server provider** (new, `server/providers/openssh-server/`).
  Installs the Windows OpenSSH Server optional capability, sets `sshd` to
  Automatic and starts it, opens TCP 22 inbound, and asserts
  `PasswordAuthentication yes` in `sshd_config` (matches mastw, where SSH
  with `mast` / `physics` is the working entry point). Order 8 -- runs very
  early so the inbound channel is available for diagnostics even if a later
  provider fails. Added to `build-mast.ps1` module list. No asset; uses the
  in-box capability.
- **windows-exporter-monitoring provider** (new,
  `server/providers/windows-exporter-monitoring/`). Provider script +
  module.json install the official MSI as a LocalSystem auto-start service
  listening on TCP 9182 and open the matching firewall rule. Now enabled in
  the build module list (the MSI was supplied by the upstream merge below).
  Also runs `fix-perf-counters.ps1` first to repair Perflib enumeration on
  IoT LTSC images where windows_exporter's PerfData collectors otherwise
  silently drop core OS series. The provider name carries the
  `-monitoring` suffix to make it clear from the build module list that it
  is the metrics-export piece (other monitoring providers - log forwarders,
  alert agents - may join later).
- **MongoDB Compass enabled in mongodb-client.** The existing
  `mongodb-client` provider already ships `mongodb-compass-1.43.0-win32-x64.exe`
  and has install logic gated by `-NoCompass`. Flipped the module.json
  command to drop the `-NoCompass` flag so Compass installs alongside the
  client tools. No new provider folder; the parallel-provider sketch in the
  plan was redundant once we noticed the existing wiring.
- **Astrometry.net Local Solver is *already* in the cygwin provider** (lines
  98-106 of `provide-cygwin.ps1`). The optional `astrometry.tgz` asset is
  extracted into `C:\cygwin64\usr\local\astrometry`. The GAPS.md item is
  therefore an asset-shipping question, not a code question -- the cygwin
  provider must be staged with a real `astrometry.tgz` (currently TestMode-
  exempt at `build-mast.ps1` line 347, so dev builds skip it). Once the
  index bundle is available, drop it under `server/providers/cygwin/assets/`
  and remove the TestMode exemption to make it required for prod builds.
- **ImDisk reshape: ramdisk -> file-backed persistent mount.**
  `provide-imdisk.ps1` previously registered a startup task that created an
  empty 10 GB ramdisk at D: each boot. That diverged from mastw, which
  mounts `D:` from `C:\MAST\Shared\MAST-10GB-with-indexes.img` so the
  indexes survive reboots. The provider now (a) ensures `C:\MAST\Shared\`
  exists, (b) warns if the `.img` is absent at provider-run time without
  failing the run, (c) registers a new task `MAST-ImDisk-Persistent` whose
  action is `imdisk -a -m D: -f "<image>"` triggered AtStartup, and (d)
  unregisters the legacy `MAST-ImDisk-Ramdisk` task on machines that have
  it. The image file is supplied out-of-band per GAPS.md.
- **Wireshark + Npcap.** `provide-wireshark.ps1` now looks for
  `npcap-*.exe` under `AssetsRoot` after the Wireshark install and runs it
  silently with `/loopback_support=yes /winpcap_mode=yes /admin_only=no`
  (matches mastw's capture posture). The provider gracefully no-ops if no
  Npcap installer is found and logs a `[WARN]` line. `module.json`
  commandfiles is intentionally NOT updated, because build-mast is strict
  about commandfiles existing; once Npcap is acquired, add the asset and a
  matching commandfiles entry (or a TestMode exemption).
- **build-mast.ps1 module list.** Added `'openssh-server'` near the top
  (after `proxy`) and `'windows-exporter-monitoring'` near the bottom
  (after `zwo`, before `reboot`).

**Implications:**

- The new VM should now end up with sshd reachable on TCP 22 with
  `mast` / `physics`, matching mastw's inbound posture. Once that lands,
  GAPS.md line 169 ("mastw: WinRM stopped (Manual), sshd running") becomes
  symmetric and the host can drive comparisons against either box.
- MongoDB Compass is now installed by default. If a future site does not
  want a GUI, add a host-specific flag rather than reverting the module
  default.
- `npcap-*.exe` is the remaining gap item still blocked on asset
  acquisition. The windows_exporter MSI (0.31.7) and a stripped
  `astrometry.tgz` arrived via the upstream merge described in the
  [2026-05-24] entry above; both providers are now enabled by default.
- The ImDisk task name change (`MAST-ImDisk-Ramdisk` ->
  `MAST-ImDisk-Persistent`) is handled gracefully on upgrade: the provider
  unregisters the old task before registering the new one. Any external
  monitoring that grepped the old task name needs updating.
- Version pinning (ASCOM 7.0 RC4, PHD2 2.6.14dev1mast03, ZWO 6.5.20,
  PlaneWave Shutter 1.15.0, Python 3.12.2, ASIStudio 1.14.0.0) is also
  blocked on asset acquisition. The `pin_target` informational field from
  Phase 1 makes the queue greppable:
  `Select-String pin_target server/providers/*/module.json`.
- NoMachine Server verification (whether `enterprise-desktop` actually
  installs the server side correctly) is deferred to the post-deploy
  smoke test described in the Phase 2 plan -- no code change needed in
  this push.

---

## [2026-05-18] Phase 1 closure of mastw vs VM gap: service name, proxy, bootstrap, reboot

**Why:** `compare-mastw/GAPS.md` (2026-05-18) catalogued the divergences
between the hand-built `mastw` unit and the automatically provisioned
`mast-wis-01` VM. A subset of the gaps is cross-cutting infrastructure that
must be reconciled before adding new providers makes sense: the service name
is spelled differently on each side (so `Get-Service` calls break against the
wrong machine), the VM is missing the Weizmann proxy env vars (silent network
failures inside the lab), the bootstrap renames the OEM account in a way that
strands `%USERPROFILE%` at `C:\Users\user` instead of `C:\Users\mast`, and
provisioning runs leave a `pendingFileRename = True` state with no follow-up
reboot. These four problems are addressed together; new-provider work
(NoMachine Server, ImDisk + scheduled task, windows_exporter, openssh-server,
Astrometry.net, MongoDB Compass) and version-pin downgrades stay deferred to
Phase 2 because they need installer assets we do not yet have.

**What:**

- **Service-name canonicalization.** The Windows service is now spelled
  `MAST-Unit` (hyphen) everywhere code reads or writes it: `provide-mast.ps1`
  registers and manages it under that name, `verify-mast.ps1` and
  `verify-diagnostics.ps1` reference it by hyphen, `vm/run-prov-test.py`'s
  start/stop helpers updated, and the unit-side service definition in
  `MAST_unit.2024-12-12/service/mast-service.ps1` uses the hyphen too.
  Filesystem paths and repo names that contain the substring `MAST_unit`
  (e.g. the `MAST_unit.2024-12-12` repo, the `services/mast-unit/` folder)
  are left alone -- they are not the service name.
- **`proxy` provider.** New `server/providers/proxy/` with
  `provide-proxy.ps1` + `module.json`, order 5 so it runs before anything
  that does network I/O. Sets machine-scope `http_proxy`, `https_proxy`,
  `no_proxy` to the mastw values (`http://bcproxy.weizmann.ac.il:8080`,
  no_proxy = `10.23.3.0/24,10.23.4.0/24`). Idempotent; reads back to verify
  the values stuck before exiting.
- **Bootstrap user-creation policy.** `client/bootstrap-winrm.ps1` no longer
  renames the OEM `user` account to `mast`. It now creates a separate
  `mast` local administrator (the existing block at lines 202-229 already
  did this; the change is removing the rename block that ran before it).
  `-FactoryUser` is preserved as a deprecated no-op so existing
  autounattend invocations keep working. Forward-only: existing
  `mast-wis-01` will be re-imaged rather than fixed in place.
- **Reboot detection + orchestrator handling.** New `server/providers/reboot/`
  runs last in the build module list and writes
  `C:\MAST\state\reboot-requested.flag` when Windows reports a pending
  reboot (`PendingFileRenameOperations`, CBS `RebootPending`, or Windows
  Update `RebootRequired`). The detector always exits 0 so it cannot fail a
  run. `execute-mast-provisioning.ps1` gains an `-AllowReboot` switch; in
  its `finally`, after lease release, if `exitCode == 0` and `-AllowReboot`
  was passed and the flag is present, it deletes the flag and issues
  `shutdown /r /t 60`. `server/check-and-provision.ps1` now passes
  `-AllowReboot`; manual operators get the deferred path by default.
- **Version-pin TODO markers.** `ascom`, `phd2`, `zwo`, `planewave`, and
  `python` module.json files gained a `pin_target` informational field
  naming the mastw version target. `build-mast.ps1` ignores the field;
  it exists so `Select-String pin_target server/providers/*/module.json`
  surfaces the remaining downgrade work as Phase 2.

**Implications:**

- Units already in service with the old `MAST_unit` service name will keep
  running until they are re-provisioned. The next provisioning run will see
  no `MAST-Unit` service and register it; the old `MAST_unit` is not
  migrated. Out of Phase 1 scope to clean up.
- The reboot provider is conservative: it only suggests a reboot, never
  forces one. The orchestrator gate (`-AllowReboot`) means manual runs of
  `execute-mast-provisioning.ps1` will leave the flag in place and log a
  deferred-reboot notice. The next autonomous cycle picks it up. This
  matches the "REBOOT ME" pattern requested in GAPS.md.
- New autounattend-installed VMs will end up with `C:\Users\mast\` as the
  operational profile and an untouched OEM `user` account. The existing
  `mast-wis-01` VM still has the stranded `C:\Users\user` profile and will
  not be remediated -- we re-image instead.
- The `proxy` provider hardcodes the Weizmann values. If MAST is ever
  deployed at a site with a different web proxy, this provider needs to
  read the values from `vault/creds.json` (or similar) rather than
  baking them in. Out of scope for now; we have one site.
- Phase 2 must still tackle: new providers (Astrometry.net, MongoDB
  Compass, ImDisk + scheduled task, windows_exporter, NoMachine Server
  replacing the Client, openssh-server, Wireshark/Npcap addition);
  acquiring the older installer assets to actually act on the `pin_target`
  markers; and the Win11-vs-Win10-IoT SKU question (accepted as
  non-actionable in GAPS.md but worth a follow-up if real production
  hardware ships).

---

## [2026-05-17] Resilient WinRM Receive loop; decouple WSMan op timeout from script timeout

**Why:** The host orchestrator was repeatedly aborting successful unit-side
runs mid-execute. `execute-mast-provisioning.ps1` would reach `LEASE_RELEASE`
and exit cleanly, but `run-prov-test.py` kept ticking `run_ps still running`
for the remainder of the WinRM call timeout (`WINRM_CALL_TIMEOUT_S`, 1 h)
and ultimately marked the cycle as failed. Three findings out of the spike:

1. `vm_lib.winrm_session()` was setting `operation_timeout_sec` to the full
   1 h script ceiling. That tells the WinRM service to hold a single `Receive`
   SOAP request open for up to an hour waiting for output, and pywinrm
   correspondingly waits up to an hour on the underlying TCP `recv`. A long
   silent stretch during heavy install IO (.NET 3.5 via SYSTEM DISM scheduled
   task + ASCOM Platform installer) lined up with a transient TCP glitch, the
   socket went half-dead, the single mega-Receive never returned, and the
   host never saw `CommandState=Done`.
2. pywinrm's `Session.run_ps` only handles `WinRMOperationTimeoutError` mid
   command. Any `requests.ReadTimeout` / `ConnectTimeout` / `ConnectionError`
   bubbles up out of `session.run_ps`, after which the shell + command IDs are
   lost — even though the *running command on the unit is unaffected and the
   server still has its output buffered*.
3. The `requests.Session` connection pool can hold stale half-dead sockets
   that survive single transient failures, so retrying naively against the
   same pool reproduces the same timeout. A host reboot cured one stuck run
   precisely because it flushed the pool.

Prior misdiagnosis: the 2026-05-16 entry attributed an earlier instance of
this symptom to `Register-ObjectEvent`/PSEventJob teardown on the unit. The
lease renewer was a real PSEventJob hang and that fix stands, but the
*recent* "stuck after `LEASE_RELEASE`" symptom is a different bug entirely
and lives on the host. The unit-side `Register-ObjectEvent` ban remains
good guidance (see CLAUDE.md DO NOT list) but is not the cause being fixed
here.

**What:**
- `vm/vm_lib.py`: introduced `_WSMAN_OP_TIMEOUT_S=60`, `_WSMAN_READ_TIMEOUT_S=120`
  for `winrm_session()`. WSMan now polls every ~60 s; the HTTP client has 60 s
  of slack over each server-side wait. The 1 h ceiling is the
  `_run_with_heartbeat` `timeout_s`, not the WSMan call timeout.
- New `_resilient_get_command_output()` drives the WSMan Receive loop via
  the lower-level `Protocol._raw_get_command_output` API. It swallows
  `WinRMOperationTimeoutError` (expected mid-command) and catches transient
  HTTP / transport errors (`requests.ReadTimeout`, `ConnectTimeout`,
  `ConnectionError`, `ChunkedEncodingError`, `winrm.exceptions.WinRMTransportError`).
  On a transient, it evicts the local `requests.Session` connection pool
  (`_evict_winrm_connection_pool`) so the next Receive dials a fresh TCP
  socket, then retries against the *same* `shell_id` + `command_id`. The
  server has the output buffered through the shell's IdleTimeout window
  (~2 h default on Windows Server SKUs); the running command never knew
  anything went wrong.
- New `_resilient_run_ps()` wraps the above with shell open / command
  start / cleanup_command / close_shell in `finally` blocks, mirroring
  `Session.run_ps()` (UTF-16 LE base64 → `powershell -EncodedCommand`).
- `run_ps()` now routes through `_resilient_run_ps()` instead of
  `session.run_ps()`. Public signature unchanged; the heartbeat / hard
  timeout layer above is unaffected.
- Retry budget: 10 minutes of *consecutive* failed state, with the deadline
  reset on every successful Receive — each fresh glitch gets the full
  grace window. Backoff between retries: 3 s.
- `client/execute-mast-provisioning.ps1`: reverted the `[Environment]::Exit($code)`
  workaround back to a plain `exit $script:exitCode`. The workaround was
  patched in to mask the original `Register-ObjectEvent` hang on the unit;
  with the host-side resilience layer in place, a clean PS exit is preferred
  so the WSMan shell sends a proper `CommandState=Done` response. The
  former line is kept commented in place per the project rule on disabling
  rather than deleting, with a note explaining why it must not be reinstated
  without first confirming via teardown breadcrumbs that PS teardown is
  actually hanging.
- New teardown breadcrumbs in `execute-mast-provisioning.ps1` (a small
  helper writing timestamped `TEARDOWN ...` lines: reached_exit_point,
  inventory of event subscribers / PS jobs, exit_code). These are how the
  spike ruled out the PSEventJob theory and localized the bug to the host.
  They stay as observability for any future "stuck at exit" symptom.
- New `Get-MastVerifyDir` call at startup so per-provider `verify` commands
  in `module.json` can `Out-File` into `C:\MAST\logs\verify\` without
  pre-creating the directory themselves (they run as separate `powershell.exe`
  children and cannot dot-source `mast-log.ps1`).
- `server/providers/ascom/module.json`: verify command now sets
  `$ErrorActionPreference='Stop'` so a failing `Out-File` actually fails
  the verify (the original silent pass masked the missing-directory bug).

**Implications:**
- We are committed to pywinrm's `Protocol._raw_get_command_output` — a
  private API. The method name has been stable across pywinrm versions for
  years; if it ever changes, `_resilient_get_command_output` is one file
  to update. The alternative (using `Protocol.get_command_output` directly)
  cannot do same-shell retry, which is the whole point.
- A genuinely wedged unit (no WinRM response for >10 min, plus no other
  signal) will still abort the cycle. That is the right behavior — at that
  point the unit needs human attention. If we ever want completion to
  survive arbitrarily long WinRM blackouts, the architectural move is to
  add an SMB-based completion sentinel (`installed-manifest.json` already
  lives on the unit; could mirror to `mast-shared`), with WinRM degraded
  from "on the critical path for completion" to "log harvester + initiator."
  Not built today; flagged for future work.
- WSMan poll cadence of 60 s means a worst-case ~60 s lag between unit
  script exit and the host observing `CommandState=Done`. Acceptable.
- `WINRM_CALL_TIMEOUT_S` is preserved as the heartbeat / hard ceiling and
  still drives `--winrm-call-timeout-s`. It no longer flows into WSMan
  session construction.

---

## [2026-05-16] Drop in-process lease renewer; size LeaseTtlSeconds to cover worst-case runs

**Why:** The lease renewer introduced in the prior entry used a
`System.Timers.Timer` + `Register-ObjectEvent -Action` to re-stamp
`expires_utc` every 60 s. Under WinRM this hung every clean-exit run:
`execute-mast-provisioning.ps1` reached `exit 0` and the `finally` block
ran as far as `Write-Log "Log file: ..."`, then `powershell.exe` froze
forever without emitting `LEASE_RELEASE`. The Python orchestrator's
`run_ps still running` heartbeat was the only signal. Root cause is a
known PSEventJob teardown trap: `powershell.exe` waits for all event
subscribers to drain before returning to the WinRM caller, and an
in-flight Elapsed action plus `Unregister-Event` can deadlock the engine
event queue with no timeout. The renewer's correctness benefit (lease
expiry never overruns a slow install) is not worth a primitive that
silently hangs every successful run -- especially given that observed
end-to-end provisioning on a slow VM runs about 40 minutes, well inside
a single fixed-TTL window.

**What:**
- `client/execute-mast-provisioning.ps1`: removed the `Timers.Timer`
  + `Register-ObjectEvent -Action` block and the matching teardown
  (`Stop`/`Dispose`/`Unregister-Event`/`Get-Job`/`Remove-Job`) from
  `finally`. The lease is written once at acquire time and released
  in `finally`; nothing touches the file in between.
- `LeaseTtlSeconds` default kept at 7200 (2 h). A real provisioning
  cycle on a slow VM is ~40 min today, so 2 h is roughly a 3x margin
  on the worst case we have evidence for; that is the right cap until
  measured runs say otherwise. Callers that want a tighter window can
  still pass `-LeaseTtlSeconds` explicitly.
- Comment left at the former renewer site documenting the WinRM hang
  and explicitly forbidding reintroduction of `Register-ObjectEvent`
  here. The same ban is recorded in `CLAUDE.md` under the PS 5.1
  DO NOT list.

**Implications:**
- A crashed run with a still-live owning pid blocks the next cycle for
  up to 2 h before `LEASE_STALE_TAKEOVER` triggers. The pid-liveness
  check still lets the next cycle take over immediately when the prior
  `powershell.exe` is gone, so the 2 h ceiling only matters when the
  prior pid is somehow still alive but stuck.
- The lease TTL and the `availability.json` reason=`provisioning` TTL
  both sit at 2 h, so the two recovery clocks stay aligned.
- If a future workload genuinely needs sub-TTL renewal, run the renewer
  as a child `powershell.exe` (`Start-Process -PassThru`, killed in
  `finally` via `Stop-Process`) so its lifetime is decoupled from the
  parent runspace. Do not reintroduce `Register-ObjectEvent` in any
  WinRM-invoked script.

---

## [2026-05-16] Lease record + availability TTL + last-run heartbeat replace sticky lock file

**Why:** Three Phase 1 gaps blocked safe activation of the prov-server
scheduled task. (1) `client/execute-mast-provisioning.ps1` used a sticky
`C:\MAST\execute.lock`; a crashed run left the file behind and blocked all
future provisioning until a human deleted it. (2) `server/check-and-provision.ps1`
wrote `availability.json` with `available:false, reason:provisioning` before
execute and `available:true` on success -- if the driver died between the
two writes, the unit was silently removed from MAST scheduling indefinitely
(no TTL, no recovery, no reader). (3) A crashed driver surfaced in Task
Scheduler; a hung one did not. No `last-run.json` existed and no in-cycle
progress was emitted during the long transfer/execute steps, so a stuck
cycle was indistinguishable from a slow one. All three are the same shape
of bug -- a state file with no freshness contract -- so they are addressed
together with one pattern.

**What:**
- New shared helpers in `server/lib/mast-log.ps1`:
  `Get-MastStatusBase` (always returns `<SystemDrive>\MAST\status`, typically
  `C:\MAST\status` -- co-located with logs and `installed-manifest.json` so
  every unit-side state file lives under one tree, rather than splitting
  across `C:\MAST\` and `C:\ProgramData\MAST\`),
  `Get-MastExecuteLeasePath`, `Get-MastAvailabilityPath`, `Get-MastLastRunPath`,
  and `Write-MastStatusFileAtomic` (`.tmp` + `Move-Item -Force`). All three
  status-file writers across the repo now go through the same code path.
- `client/execute-mast-provisioning.ps1`: lock file replaced with a lease
  record at `C:\MAST\status\execute-lease.json`. Fields:
  `run_id`, `held_by`, `pid`, `started_utc`, `expires_utc`, `ttl_seconds`.
  New parameters `-RunId`, `-HeldBy`, `-LeaseTtlSeconds` (default 7200 = 2 h).
  Acquire: refuse with `LEASE_HELD` if `now < expires_utc` AND owning pid is
  alive; otherwise log `LEASE_STALE_TAKEOVER` and overwrite. Renew: a
  `System.Timers.Timer` re-stamps `expires_utc` every 60 s. Release: only
  the owning run_id deletes the file (defensive against an intervening
  takeover). Legacy sweep removes any pre-migration `execute.lock` artifacts.
- `availability.json` schema extended so every `available:false` write
  includes mandatory `expected_return_utc` and `lease_owner`. TTL policy:
  `provisioning` = 2 h (matches lease), `windows_update` = 1 h, `rebooting`
  = 15 min, `maintenance` = window end, `smoke_failure` = 30 min.
  `available:true` writes do **not** include these fields.
- `server/check-and-provision.ps1`: new pre-cycle availability read after
  WinRM session open. If `available:false` and `lease_owner` is a prior run
  AND `now > expected_return_utc`, log `AVAIL_STALE_RECOVER` and proceed.
  If the lease is still live (`now <= expected_return_utc`), log
  `AVAIL_LEASE_LIVE` and skip with activity outcome `SKIP /
  reason=avail_lease_live`. The driver also passes `-RunId $RunId
  -HeldBy $env:COMPUTERNAME` when invoking `execute-mast-provisioning.ps1`
  so the unit-side lease ties back to the driver run.
- Prov-server heartbeat: at cycle exit the driver writes
  `C:\MAST\status\last-run.json` via
  `Write-MastStatusFileAtomic` with `run_id`, `started_utc`, `ended_utc`,
  `duration_s`, `units_checked`, `units_updated`, `units_failed`,
  `unit_outcomes`, `exit_code`. A `Phase 3` alert can fire when
  `now - ended_utc > 2 * scheduled_interval`. During long transfer/execute
  phases a `System.Timers.Timer` emits `UNIT_PROGRESS unit=... phase=... elapsed_s=...`
  every 60 s so a hung cycle is visible in the run log.
- `client/onboard-mast-unit.ps1` Stage 5 routed through the shared atomic
  writer for schema consistency (writes `available:true`, no TTL fields).

**Implications:**
- The sticky lock failure mode is gone. A crashed unit-side execute is
  recovered automatically on the next cycle once `expires_utc` passes;
  no manual file deletion required.
- The stuck-on-`provisioning` availability failure mode is gone. The MAST
  scheduler can treat any `available:false` with `now > expected_return_utc
  + grace` as stale -- documented in the autonomous-provisioning doc under
  **Autonomous recovery from common failure modes**.
- `last-run.json` is the single source of truth for "when did the prov
  server last complete a cycle". Phase 3 alerting will consume it (or the
  Prometheus metric derived from it) without parsing `activity.csv`.
- `expected_return_utc` is currently a fixed conservative cap per reason
  rather than a value derived from recent `activity.csv` run durations.
  That resolves the doc's Open Question on lease/availability TTL semantics
  for now; revisit once a few weeks of real-fleet durations exist.
- `executable-mast-provisioning.ps1` now has two flavors of invocation:
  autonomous (driver passes `-RunId`/`-HeldBy`) and manual (run_id is
  auto-generated as `exec-<timestamp>-<pid>`). Both paths exercise the
  same lease code, so a developer running the script by hand also acquires
  a lease and will collide with any in-flight autonomous run -- intentional.
- `installed-manifest.json` is unchanged by this work and stays at
  `C:\MAST\installed-manifest.json`; the new status files sit alongside it
  under `C:\MAST\status\` so the entire unit-side state tree is one place.

---

## [2026-05-16] check-and-provision.ps1: maintenance-window enforcement

**Why:** `unit-registry.json` has carried `maintenance_window: { start_hour, end_hour }`
and `timezone` per unit since the autonomous-provisioning design landed, but the
driver never consulted them. Closing this Foundation [PARTIAL] gap is a prerequisite
for activating the scheduled task on the prov server -- without it, an unattended
fire on a 30-minute cadence could trigger transfers and reboots at arbitrary local
times. Phase 1 work (driver heartbeat, lease replacement) is independent and can
land afterward.

**What:**
- New helper `Test-InMaintenanceWindow` in `server/check-and-provision.ps1`.
  Resolves the unit's `timezone` via `[System.TimeZoneInfo]::FindSystemTimeZoneById`,
  converts `UtcNow` to that zone, and returns allowed/current/window/tz. Handles
  the wrap case (`end_hour < start_hour`, e.g. 22-06). Missing window or invalid
  timezone falls back to "allowed" with a `MAINT_TZ_WARN` log -- a partially
  configured registry never blocks the loop.
- Gate placed **after** the hash check and DryRun handling, **before** the
  "mark unavailable / SMB pull / execute" sequence. Hash-only "needs update?"
  probes therefore still run at any time; only disruptive steps are gated.
- New script parameters `-MaintenanceWindowStart` / `-MaintenanceWindowEnd`
  (default `-1` = unset). When both are supplied, they override the per-unit
  registry values for ad-hoc fleet-wide pushes.
- Skipped units log `MAINT_SKIP` (event) and `SKIP_MAINTENANCE` (activity.csv
  outcome) so per-unit accounting stays consistent each cycle.

**Implications:**
- The scheduled task can now be activated unattended without risk of mid-day
  disruption to units with a defined window.
- Registry entries without a `maintenance_window` field still get provisioned
  on any cycle -- callers who want strict gating must populate the field.
- Activity-CSV consumers (future Phase 3 dashboards) gain a new outcome value
  `SKIP_MAINTENANCE` distinct from `SKIP` (already-current / dry-run).

---

## [2026-05-16] Build manifest: aggregate per-module versions

**Why:** The autonomous-provisioning design has long called for a `module_versions`
map in `build-manifest.json` so the fleet can answer "what version of python is on
mast03?" without remoting in, and so regression hunts can correlate failures with
specific package bumps. The field was specified but never emitted; provider
`module.json` files had no `version` key, and `build-mast.ps1` did not aggregate
one. This entry closes that Foundation [PARTIAL] tag.

**What:**
- Every provider `module.json` under `server/providers/*/` (19 files) now carries
  a `version` string positioned immediately after `name`. Values reflect the
  bundled installer asset where one exists (e.g. python -> `"3.12.0"`,
  git -> `"2.52.0"`, wireshark -> `"4.6.0"`). Source-tracked modules use the
  literal `"git"` (mast); modules with no external versioned payload use
  `"builtin"` (diagnostics) or `"rolling"` (sysinternals); composite modules use
  a slash-joined string (e.g. mongodb-client ->
  `"mongosh-2.2.6/tools-100.9.4"`). Values are informational, not gating.
- `build/build-mast.ps1` now iterates `${Modules}` before constructing the
  manifest object, reads each `module.json` via the existing
  `Read-ModuleManifest` helper, throws if `version` is missing or whitespace,
  and substitutes the literal `"git"` with `$gitSha`. The aggregated
  `[ordered]` hashtable is attached to the manifest as `module_versions`.
- `client/execute-mast-provisioning.ps1` (lines 220-238) already copies the
  build manifest verbatim into `installed-manifest.json`, so the new field
  propagates to units without any change there.

**Implications:**
- Adding a new provider now requires a `version` field -- a missing one fails
  the build loudly rather than emitting a manifest with silent gaps.
- The `git` sentinel keeps source-tracked modules meaningful without burdening
  provider authors with templating logic.
- The next provisioning cycle on every unit will produce a fresh
  `installed-manifest.json` carrying `module_versions`, enabling fleet-wide
  version queries without remoting in.

---

## [2026-05-16] vm/ test infrastructure: vm_lib shared module + named test-suite scenarios

**Why:** Two pressures converged. (1) During VM bring-up debugging, ~15 ad-hoc
Python scripts accumulated in `vm/` (`_check_logs.py`, `_patch_common.py`,
`_rename_vm*.py`, ...) all of which re-instantiated `winrm.Session` directly
and re-read `vault/creds.json` inline -- a direct violation of the DRY rule in
`CLAUDE.md` and a recurring source of drift. (2) `run-prov-test.py` was the
only test path against a unit, but it has no named, repeatable scenarios for
common provisioning regressions (mid-stream failure, recovery without
snapshot, per-module idempotency without the UNIT_SKIP shortcut). We needed
canonical helpers AND a thin scenario harness on top of them.

**What:**
- `vm/vm_lib.py`: new module. Extracted `load_creds`, `winrm_session`,
  `wait_for_winrm`, `run_ps`, `check_rc`, `_ps_escape`,
  `_dispose_winrm_session` and their internal helpers
  (`_run_with_heartbeat`, `_candidate_users`, `_format_winrm_stderr`) out of
  `run-prov-test.py`. Added `upload_file_b64` (base64-chunked text upload
  lifted from `_patch_common.py`). Module is import-pure; callers rebind
  `vm_lib.log_fn` / `vm_lib.log_raw_fn` to tee through a session log.
- `vm/run-prov-test.py`: now imports the helpers from `vm_lib` and reassigns
  `vm_lib.log_fn` / `log_raw_fn` to its tee-to-file logger. Single source of
  truth restored.
- `vm/DEBUGGING.md`: new doc. Codifies the convention for throwaway debug
  scripts -- name them `debug_*.py`, use `vm_lib` helpers, never instantiate
  `winrm.Session` directly, delete or promote-to-vm_lib when done.
- 15 untracked `_*.py` scripts and `vm/__pycache__/`: deleted.
- `vm/test-suite.py`: new driver. Defines 11 named scenarios (5 ACTIVE, 6
  STUB); spawns `run-prov-test.py` as a subprocess per phase sub-invocation
  and asserts on exit codes plus, where relevant, on unit-side state read via
  `vm_lib`. ACTIVE scenarios: `full-provision`,
  `full-provision-verify-only`, `interrupted-inject-fail` (deterministic
  bomb at order=65, expect non-zero then clean re-run after reset),
  `failure-recover-no-reset` (marker-gated sporadic bomb, attempt 1 fails,
  attempt 2 succeeds against the same unit), `idempotent-after-manifest-wipe`
  (full provision, delete `installed-manifest.json` on unit, full provision
  again, assert same `payload_hash`). Writes
  `C:\MAST\logs\dev\tests\<stamp>\suite-results.json`.
- `MAST_provisioning/README.md`: cross-references added for `vm_lib.py`,
  `test-suite.py`, and `DEBUGGING.md`, including a short "Named scenarios"
  subsection under the dev/test loop.

**Implications:**
- Direct `winrm.Session(...)` instantiation is now forbidden anywhere under
  `vm/` outside `vm_lib.winrm_session()` and `vm_lib.wait_for_winrm()`.
  `CLAUDE.md`'s DRY section already encoded this rule for `run-prov-test.py`;
  the canonical factory is now in `vm_lib` and applies to every script in
  the directory, including test-suite and future debug scripts.
- The two `test-suite.py` bomb injectors patch
  `staging/<hostname>/01-provisioning/commands.json` AFTER the `build`
  sub-invocation. This is a deliberate, narrowly-scoped exception to the
  "do not edit staging/" convention: the patch is ephemeral (the next
  `build` sub-run regenerates the file), is colocated with the test driver,
  and is documented in code with a comment pointing here.
- Smoke-marker-set equality assertion for `idempotent-after-manifest-wipe`
  is deferred: the current implementation asserts `payload_hash` equality
  across the two runs but does not yet diff the per-module smoke marker
  contents. Adding that requires parsing the `results.json` artifact
  `run-prov-test.py` writes under `C:\MAST\logs\dev\<stamp>-cycle<N>\` and
  is a known future enhancement (no separate tracking doc; recorded only
  here).
- The six STUB scenarios are deliberately not failures: the suite reports
  them as SKIP so they do not block CI while their implementations land.

## [2026-05-16] Remove DLI power switch stub from provisioning tests

**Why:** The DLI stub (`dli-power-stub.py`) was a transient NSSM service started by the test
orchestrator to satisfy `DliPowerSwitch.probe()` on MAST_unit startup during VM provisioning
tests. It required both NSSM and Python 3.12 to be installed before it could start, but both
are installed during the execute phase — creating an ordering dependency that could not be
satisfied without either splitting the execute phase or pre-installing prerequisites inside
the stub launcher. Rather than patch around the ordering, the MAST_unit service itself was
made fault-tolerant: it now starts and serves `/status` with errors reported regardless of
whether hardware or config is reachable.

**What:**
- `client/dli-power-stub.py`: deleted.
- `build/build-mast.ps1`: removed staging block for `dli-power-stub.py`.
- `vm/run-prov-test.py`: removed `DLI_STUB_*` constants, `phase_start_dli_stub`,
  `phase_stop_dli_stub`, and the `try/finally` wrapper around the execute/verify block in
  the cycle loop.

**Implications:** Provisioning test cycles no longer attempt to start or stop a stub power
switch service. The MAST_unit service is expected to start without hardware present and
report component failures via `CanonicalResponse.errors` in the `/status` response. The
`power_switch.network.ipaddr = "127.0.0.1"` setting in the MongoDB test unit document
(added in the VM naming entry below) is now irrelevant during tests and should be set to
the real switch address when the physical unit is deployed.

## [2026-05-16] Test VM unit name: mast-wis-01 (site-qualified canonical format)

**Why:** MAST unit hostnames follow the same site-qualified pattern as control and spec
machines: `mast-<site>-<role>`. For numbered units, role is the two-digit unit number, e.g.,
`mast-wis-01` for unit 1 at the WIS site. This is consistent with `mast-wis-control` and
`mast-wis-spec`. The test VM was initially provisioned as `MAST01` (wrong - that is not a
recognized canonical form) and then briefly as `MASTW` before the correct convention was
established. Using the site-qualified name also avoids a latent bug in `canonic_unit_name()`
where the `mastXX` path calls `name.isdigit()` (always False) instead of `suffix.isdigit()`;
the `mast-<site>-NN` path is handled by a separate regex branch.

**What:**
- VM hostname renamed from `MAST01` -> `MASTW` -> `MAST-WIS-01` via `Rename-Computer`.
- Host `C:\Windows\System32\drivers\etc\hosts`: added `192.168.56.110 mast-wis-01`
  (also `mastw` and `mast01` remain for backward compatibility during transition).
- MongoDB `mast.units`: document renamed `mastw` -> `mast-wis-01`; removed `mast01`
  test-override document; `power_switch.network.ipaddr = "127.0.0.1"` (DLI stub for test).
- MongoDB `mast.sites` wis: `unit_ids` and `deployed_units` updated from `"w"` to
  `["mast-wis-01"]`.
- `MAST_common/config/__init__.py`:
  - `Config.__init__`: added `.lower()` to hostname before site detection (Windows
    `socket.gethostname()` returns uppercase); extended regex from
    `^mast-([^-]+)-(?:control|spec)$` to also match unit numbers
    `^mast-([^-]+)-(?:control|spec|\\d+)$`.
  - `get_unit()`: added `unit_name = unit_name.lower()` so Windows uppercase hostnames
    are normalized before MongoDB lookup.
- `MAST_common/utils.py`: extended `canonic_unit_name()` with a new branch for the
  `mast-<site>-NN` format (regex `-([a-z]+)-(\\d+)$` on the suffix).
- `build/build-mast.ps1`: updated `ValidatePattern` to also accept `mast-<site>-NN`.
- `vm/run-prov-test.py`: updated `--host-unit` / `--hostname` examples and defaults.

**Implications:** All provisioning test runs must pass `--host-unit mast-wis-01 --hostname
mast-wis-01` (or rely on the updated defaults). The `mast-wis-01` MongoDB unit document is
test-configured with `ipaddr = "127.0.0.1"` (DLI stub); the production power switch address
must be set when the physical unit is deployed. The `canonic_unit_name` `name.isdigit()` bug
in the `mastXX` path is NOT fixed here (deferred); ns-site units provisioned as `mast-ns-NN`
will use the new branch and will not hit it.

## [2026-05-16] diagnostics verify: ASCOM-diagnostics path corrected; MAST_unit heartbeat port corrected

**Why:** Two checks in `verify-diagnostics.ps1` produced hard FAILs due to wrong search paths and a wrong default port. (1) The hardcoded candidate list and recursive fallback used the filename `ASCOM.Diagnostics.exe` (dot-separated) and paths matching a `Platform 6/7\Tools\Diagnostics\` layout. The actual install by `ASCOMPlatform710.4707.exe` places the tool at `C:\Program Files (x86)\ASCOM\Platform\Tools\ASCOM Diagnostics.exe` (space in name, `Platform\Tools\` path). (2) The MAST_unit heartbeat defaulted to port 5000, but `ServiceConfig` in `MAST_common/config/__init__.py` defaults to port 8000, confirmed by `mongo_seeds/services.json`. Both are hard FAILs by design - the ASCOM-diagnostics check verifies the tool can be launched, and the heartbeat verifies the service is up.

**What:**
- `server/providers/diagnostics/verify-diagnostics.ps1`:
  - ASCOM candidate list updated: filename changed to `ASCOM Diagnostics.exe` throughout; `C:\Program Files (x86)\ASCOM\Platform\Tools\ASCOM Diagnostics.exe` added as the first (most specific) candidate. Recursive fallback filter updated to match.
  - Default `$MastUnitPort` corrected from 5000 to 8000.
- Staging regenerated via `build-mast.ps1 -HostName mast01 -TestMode ...`.

**Implications:** ASCOM-diagnostics now finds and launches the tool correctly on the provisioned VM. MAST_unit-heartbeat now probes the correct port. Both checks remain hard FAILs when the condition is not met.

## [2026-05-15] Stage module: XILab installer child-kill strategy and re-enable in default build

**Why:** The XILab/Standa NSIS installer hangs in session 0 after deploying files because it
launches post-install child processes via `ExecWait` that can never exit without user
interaction. Specifically, `InfDefaultInstall.exe` (the Windows driver installer helper) was
the blocking child. The earlier workaround of setting a 180-second timeout and then doing a
full `taskkill /F /T` on the installer tree was unreliable and unnecessarily violent. The
root cause was identified as: NSIS extracts all files first, then runs post-install helpers
as children; in session 0 those children have no interactive user to respond to signing or
driver-install prompts. The installer is also left holding a pipe handle inherited from the
parent PowerShell process, causing `WaitForExit()` in `mast-invoke-child.ps1` to block even
after the installer notionally completes.

**What:**
- `server/providers/stage/provide-stage.ps1`: replaced the blanket timeout-kill with a
  targeted strategy. The installer is given its own stdout/stderr redirects (breaking the
  outer pipe inheritance). A polling loop waits for `XILab.exe` to appear on disk (signaling
  that file extraction is complete), then enumerates and terminates only the child processes
  the installer is waiting on via `Get-CimInstance Win32_Process` + `Stop-Process`. This
  allows the NSIS installer itself to exit cleanly with exit code 0. The full tree kill
  (`taskkill /F /T`) is retained as a last-resort fallback only if the installer has not
  exited after the deadline (240 s).
- The Standa driver is always staged via `pnputil /add-driver` after the installer exits,
  which is the correct unattended method regardless of what `InfDefaultInstall.exe` did.
- `build/build-mast.ps1`: `'stage'` uncommented and restored to the default module list.
  It was disabled on 2026-05-14 due to the unresolved installer hang.

**Implications:**
- The stage module is now included in all builds by default.
- Installer completes in ~30-50 s (vs 3+ min with the prior timeout approach) because the
  blocking child is removed promptly once files are on disk.
- If a future XILab installer version changes its post-install child process names, the
  polling loop will still work: it kills all children of the installer PID once files are
  deployed, regardless of child process name.
- The PnPUtil step is the authoritative driver staging path; `InfDefaultInstall.exe` being
  terminated before it completes is intentional and not a regression.

## [2026-05-15] run-prov-test.py: composable phase selection and per-module execute filtering

**Why:** Debugging a single module installer (e.g. stage/XILab) required a full
build-transfer-execute-verify-reset cycle against all modules. Iterating on one
provider script was slow and produced noisy output. A way to isolate individual
phases and individual modules was needed for a tight edit-run-verify loop.

**What:**
- `vm/run-prov-test.py`: `--phases` flag accepting a comma-separated list of phase
  names (build, transfer, execute, verify-run, verify, reset). Legacy mode flags
  (`--build-only`, `--execute-only`, `--build-transfer-verify`) become aliases resolved
  by a new `resolve_phases()` helper. `--pull-repos` and `--rebuild-repos` remain as
  dedicated one-shot modes hoisted above the cycle loop.
- `client/execute-mast-provisioning.ps1`: new `-Modules` string parameter
  (comma-separated). When set, filters the loaded commands list to only those whose
  module name (or base name stripped of `-verify` suffix) is in the list.
- `client/run-verify-only.ps1`: same `-Modules` parameter applied to the verify
  commands list.
- Python `phase_execute()` and `phase_run_verify_only()` pass `--modules` through
  to the PS scripts at runtime, so `--modules zwo --phases execute,verify` re-runs
  only the zwo module against an already-transferred staging payload.

**Implications:**
- Typical debug loop: `--modules stage --phases build,transfer,execute,verify`
  with `--no-reset` to skip VM reset between iterations.
- `--phases execute,verify --modules zwo` skips build+transfer entirely and re-runs
  zwo from the existing staging dir on the unit.
- `execute-mast-provisioning.ps1` staged on units provisioned before this change
  will not accept `-Modules`; the new flag is only effective after a fresh
  build+transfer.

## [2026-05-15] Shared utility extraction: mast-log.ps1, mast-client-util.ps1 (commit 325778e6)

**Why:** Bootstrap, onboard, prepare, execute, and run-verify-only all duplicated the
same logging boilerplate and client utility functions inline. Parallel copies diverge
silently. `run-prov-test.py` also had 73 lines requiring alignment with the PS scripts
on every change.

**What:**
- `server/lib/mast-log.ps1`: extended with `Get-MastLogSessionDir`, `Get-MastSmokeDir`,
  and related helpers previously copy-pasted across scripts.
- `client/mast-client-util.ps1` (new): canonical home for client-side utilities such as
  `Disable-WindowsAutoUpdate`. Staged via `build-mast.ps1` and
  `build-autounattend-iso.ps1`.
- All client scripts updated to dot-source using the two-path fallback
  (`PSScriptRoot` -> `parent/server/lib`) so they work both from repo and from staging.
- `CLAUDE.md`: added shared-utility reference table and canonical dot-source pattern.
- `vm/run-prov-test.py`: factory helpers (`winrm_session`, `_ps_escape`,
  `_find_unit_log_path`) made canonical -- never inline outside `run-prov-test.py`.
- `server/setup-smb-share.ps1`: significant refactor (206 lines changed) as part of the
  same DRY pass.

**Implications:**
- Any new PS script that needs logging must dot-source `mast-log.ps1` using the
  two-path fallback; no local function definitions.
- `mast-client-util.ps1` must be added to the staging `Copy-Item` lists in both
  `build/build-mast.ps1` and `vm/build-autounattend-iso.ps1` for any new client script
  that depends on it.
- Python orchestration helpers are canonical in `run-prov-test.py`; do not duplicate.

## [2026-05-14] mast-shared SMB share: writable Z: drive for unit machines

**Why:** Unit machines need a place to write files back to the provisioning
server (logs, diagnostics, results) without requiring CredSSP or per-unit
credentials. The existing mast-transfer account already authenticates units to
the server; extending it with write access on a separate share keeps the
credential model simple and avoids widening access on the read-only staging
share.

**What:**
- `server/setup-smb-share.ps1`: creates `<RepoTop>/shared/` and exposes it as
  `\\<server>\mast-shared` with SMB Change and NTFS Modify access for
  `mast-transfer`. The staging share is unchanged (read-only).
- `client/execute-mast-provisioning.ps1`: accepts new `-ProvServer`, `-SmbUser`,
  `-SmbPass` parameters. At startup it maps `Z: -> \\<ProvServer>\mast-shared`
  (skips gracefully if Z: is already in use) and verifies write access with a
  probe file. Z: is unmapped in the `finally` block.
- `server/check-and-provision.ps1`: passes `$provServer`, `$smbUser`,
  `$smbPass` through the execute invoke scriptblock so the unit receives them.

**Implications:**
- `setup-smb-share.ps1` must be re-run (once, elevated) on the provisioning
  server to create the `shared/` directory and the `mast-shared` SMB share.
- Units provisioned before this change had no Z: drive; they will get it on the
  next provisioning cycle automatically once the server share is created.
- If a unit already has Z: mapped to something else when provisioning runs, the
  mapping is left untouched and a log note is written -- no error is raised.

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
## [2026-05-13] Driver publisher certificate pre-trust for Stage installer (partial / deferred)

**Why:** The XILab (Stage/Standa) installer installs a kernel-mode driver whose publisher
is not in Windows' built-in TrustedPublisher store. When the installer runs in Session 0
(no interactive desktop -- i.e., any service or scheduled-task context), Windows cannot
show the "Allow this driver?" security dialog. The result is a silent hang: the installer
process never exits and provisioning times out.

**What:** `provide-stage.ps1` imports `standa-driver-publisher.cer` into the
`LocalMachine\TrustedPublisher` certificate store before launching the installer. The
certificate file is staged alongside the installer in `server/providers/stage/assets/`.
This is a best-effort measure -- the approach is partially effective but a reliable
end-to-end solution has not been confirmed yet and is deferred to a later pass.

**Implications:**
- A full solution may require additional steps (Group Policy, `certutil`, or pre-staging
  via the unattended setup phase) and needs verification in a true Session 0 context.
- The cert must be refreshed if Standa re-signs with a new key (check on Stage version bumps).
- This pattern (import to TrustedPublisher before installer runs) should apply to any other
  driver-installing providers added in future, once the approach is confirmed working.

---

## [2026-05-13] Centralized log-path library (`mast-log.ps1`) as single source of truth

**Why:** Provider scripts were each computing their own log paths independently, producing
logs scattered across multiple directories with inconsistent naming. Correlating a
provisioning run across the orchestrator, the execution engine, and individual providers
required searching multiple locations. Any change to the root log path required editing
every script that referenced it.

**What:** `server/lib/mast-log.ps1` is a dot-sourceable script that defines all shared log
path functions:

- `Get-MastLogsBase` - returns `<SystemDrive>\MAST\logs` (typically `C:\MAST\logs`)
- `Get-MastLogSessionDir` - returns the session-scoped subdirectory; creates it on first call
  and propagates the path via `$env:MAST_LOG_SESSION_DIR` so all scripts in a WinRM session
  share the same directory without being passed an explicit path argument
- `Get-MastSmokeDir` - returns `<LogBase>\smoke` for per-module smoke-test marker files
- `Get-MastVerifyDir` - returns the verification output directory

Provider scripts dot-source `mast-log.ps1` (searching `$PSScriptRoot` then `..\..\lib\`)
and call `Get-MastLogSessionDir` to obtain their log directory. `provisioning.psm1` also
imports this library so module-level helpers (`Start-ProvisionLog`) resolve to the same paths.

**Implications:**
- All provider logs for a single provisioning run land in one session directory, making
  post-run diagnosis straightforward (`cd C:\MAST\logs\sessions\<timestamp>`).
- The session directory is set once by the execution engine and inherited by all child
  scripts via the environment variable -- no plumbing changes needed in provider scripts.
- The log root (`C:\MAST\logs`) is defined in exactly one place; moving it is a one-line change.

---

## [2026-05-13] Unit registry (`unit-registry.json`) for per-unit configuration

**Why:** The build and autonomous provision loop needed a way to know which units exist,
which modules each unit should receive, and per-unit operating constraints (maintenance
window, timezone). Hard-coding this in scripts would make adding or reconfiguring a unit
require editing the orchestrator rather than data.

**What:** `server/unit-registry.json` (gitignored when it contains real credentials; a
`unit-registry.json.template` is committed) stores a JSON array of unit objects:

```json
{
  "hostname": "mast01",
  "modules": ["ascom","chrome","cygwin","git","mast","mongodb","nomachine","nssm",
               "phd2","planewave","python","stage","sysinternals","vscode","wireshark","zwo"],
  "maintenance_window": { "start_hour": 10, "end_hour": 16 },
  "timezone": "Asia/Jerusalem"
}
```

`check-and-provision.ps1` reads this file to enumerate units and passes each unit's
`modules` array to `build-mast.ps1 -Modules`. The `maintenance_window` and `timezone`
fields are reserved for Phase 1 enforcement (skip disruptive steps outside the window).

**Implications:**
- Adding a new unit to the fleet is a registry edit + first `onboard-mast-unit.ps1` run;
  no script changes required.
- Units with different hardware (e.g., no ZWO camera) get different module lists; the
  provisioning pipeline and smoke tests are the same code.
- The registry is the authoritative source of "what should be installed where"; the
  installed manifest on each unit is the authoritative source of "what is installed now".
- `unit-registry.json` is gitignored to keep WinRM credentials out of the repo. The
  template must be kept in sync with the actual schema.

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
