---
decided: 2026-11-19
status: accepted
areas:
  - services
  - reproducibility
supersedes:
---

# Provisioning vendors the nssm 2.24-101 pre-release

**Why:** MAST_supervision's `install/install-mast-service.ps1` sets `AppKillProcessTree` to 0 on `mast-service`, so a stop reaches only `service.py` and the supervisor's own teardown (app shutdown with the covers, then PHD2, PWI4, ps3cli) runs in order. By default nssm kills the whole process tree on stop. The vendored nssm 2.24 (the last release, 2014) has no `AppKillProcessTree`, so on the supervisor's dev-VM acceptance run (2026-11-17) the installer threw there, the `mast-service` provider exited 1, and the installer never reached the SCM failure actions. A crashed supervisor was then not restarted. The 2.24-101-g897c7ad pre-release (2017-04-26) supports the parameter, and it was taken as the build the supervisor's service is registered with.

**What:**

- `server/providers/nssm/assets/nssm-2.24.zip` is replaced by `nssm-2.24-101-g897c7ad.zip`, from `https://nssm.cc/ci/`, SHA256 `99f5045fffbffb745d67fe3a065a953c4a3d9c253b868892d9b685b0ee7d07b8`. Its row in `server/data/vendor-inputs.json` and `server/data/assets.json` changes with it, and `module.json` names it.
- `provide-nssm.ps1` used to skip whenever `C:\Program Files\nssm\nssm.exe` existed, which would have left every unit on 2.24. It now extracts the archive first and skips only when the installed `nssm.exe` has the same SHA256 as the archive's.

**Rejected:**

- *Have the installer skip `AppKillProcessTree` when nssm lacks it.* That keeps the 2.24 release, but 2.24 then kills the process tree on every stop, cutting off the supervisor's teardown, including the app shutdown that closes covers which may be open.
- *Keeping 2.24 beside the pre-release.* Units have one `nssm.exe` on PATH, so only one can serve.

**Unsettled:**

- A pre-release from the nssm CI, not a release. nssm has had no release since 2.24, and 2.24-101 is the build commonly installed in its place.
- Replacing `nssm.exe` needs every nssm-hosted service stopped. `mast-services-standdown` (order 20) stops `mast-service` and removes the legacy ones before this module (1200), so the copy is expected to find it free. A copy that fails fails the run.
- A new asset is only in the build host's asset cache until the first build that stages it is synced to the blobstore.

**Implications:**

- Every unit re-runs `nssm` on its next run (the archive is in the module's hash), and gets the new `nssm.exe`.
- `verify-nssm.ps1` is unchanged: it checks that `nssm.exe` runs, not which build it is.
