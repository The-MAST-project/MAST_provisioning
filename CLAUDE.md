# MAST_provisioning — guidance for AI assistants

## Scripts must be ASCII-only

Do **not** introduce non-ASCII characters into executable scripts or modules under this repo (including inside comments and string literals).

Applies at minimum to: `*.ps1`, `*.psm1`, `*.py`, `*.sh`, `*.bat`, `*.cmd`.

**Does NOT apply to** Markdown (`*.md`) or other prose documents (`*.txt`, `*.rst`, etc.) — those are read by humans and tooling that handles UTF-8 fine. Existing `.md` files in this repo already contain em-dashes, smart quotes, and similar in headings/prose; do not "fix" them, and you may use such characters in new `.md` content (including `DECISIONS.md` entries, `README.md`, `GAPS.md`).

**Why:** Windows PowerShell 5.1 often loads `.ps1` files using a legacy code page. UTF-8 sequences (smart punctuation, emoji, arrows, em dashes) can be mis-decoded and **break parsing** (unterminated strings, bogus errors far from the real line). Markdown has no such parser fragility.

**Use plain ASCII instead**, for example:

- Em dash `—` → hyphen `-` or ` - `
- Arrow `→` → `->`
- Smart quotes `'` `'` → `'`
- Ellipsis `…` → `...`
- Symbols like `✗` `⚠` `✓` → text such as `[FAIL]`, `[WARN]`, `[OK]`

If non-English text is ever required, prefer a `.md` document or locale data file saved as **UTF-8 with BOM** and keep scripts themselves ASCII-only.

## Target Windows PowerShell 5.1

Unit and host provisioning is executed under **`powershell.exe` (Desktop edition, 5.1)** — for example WinRM, WCD, and unattended staging runs. Treat **PowerShell 7+ (`pwsh`) as optional**; scripts must behave correctly in 5.1.

**DO**

- Prefer syntax and cmdlets that exist in 5.1; when in doubt, check [about_Windows_PowerShell_5.1](https://learn.microsoft.com/powershell/scripting/whats-new/migrate-from-windows-powershell-51-to-powershell-7) migration notes (use the inverse: avoid what is listed as PS7-only).
- Use classic control flow (`if` / `elseif` / `else`, `switch`, `$null -ne $x`) instead of newer operators.
- After `Start-Process -PassThru` and `WaitForExit`, treat **missing `ExitCode`** (`$null`) with care: in 5.1, `$null -ne 0` is `$true`, so **do not** use `if ($p.ExitCode -ne 0)` alone to mean failure.
- Keep `module.json` one-liner `powershell.exe ... -Command "..."` strings compatible with 5.1 parsing and quoting.

**DO NOT**

- Do **not** use PowerShell 7+-only features in `*.ps1` / `*.psm1` consumed on the unit, including: **ternary** `condition ? a : b`, **null-coalescing** `??` / `??=`, **null-conditional** `?.`, or **pipeline chain** `&&` / `||` (those operators are not available in Windows PowerShell 5.1 the same way).
- Do **not** assume `pwsh`, `$PSVersionTable.PSEdition -eq 'Core'`, or modules that only ship for PowerShell 7 without a 5.1 fallback.
- Do **not** use `if` as an inline expression inside bare parentheses `(if (...) {...} else {...})`. In 5.1, `if` inside `()` is parsed as a command name and throws `"The term 'if' is not recognized as the name of a cmdlet"`. Use the subexpression operator instead: `$(if (...) {...} else {...})`. This applies anywhere `if` appears inside a `-f` format string argument, a function call argument, or any other expression context.
- Do **not** use `Register-ObjectEvent ... -Action { ... }` (or `Register-EngineEvent -Action`) in scripts that run under WinRM. The action creates a PSEventJob bound to the engine event queue, and `powershell.exe` waits for all event subscribers to drain before returning to the WinRM caller. If an event is mid-flight at exit (or `Unregister-Event` races a running action), the process hangs indefinitely with no timeout -- the WinRM call never returns, and only the outer Python heartbeat reveals the stall. This bit `execute-mast-provisioning.ps1` once: a `System.Timers.Timer` + `Register-ObjectEvent` lease renewer hung every clean-exit run (see 2026-05-16 DECISIONS entry). If you need periodic work alongside a long-running script, run the renewer as a child process (`Start-Process powershell.exe -PassThru` + `Stop-Process` in finally) so its lifetime is decoupled from the parent runspace. Pick a TTL long enough to cover the worst-case run before reaching for periodic renewal at all. **Note:** symptoms that *look* like this bug (unit-side script finishes, but the host's `run_ps` keeps ticking) can also come from the host-side WinRM transport hanging on a single oversized WSMan Receive on a half-dead TCP socket -- that one lives in `vm/vm_lib.py` and is addressed by the 2026-05-17 resilient Receive loop, not by anything on the unit. Verify which side is stuck before reaching for renewer-style fixes; the unit-side teardown breadcrumbs at the bottom of `execute-mast-provisioning.ps1` exist for exactly that triage.

## DECISIONS.md

`DECISIONS.md` is a reverse-chronological log of architectural and design decisions.

**When to add an entry:**
- Any architectural or design decision: transfer mechanism, credential model, script
  decomposition, protocol choice, directory layout, security posture, etc.
- Do NOT add entries for debugging spikes, transient experiments, or bug fixes that
  don't reflect a deliberate design choice.

**Format:** Each entry is a dated H2 heading followed by three sections -- **Why**
(the problem or motivation), **What** (the change made), **Implications** (consequences,
constraints, or follow-on work). Match the style of existing entries.

**Date:** Always generate the date with a system command -- run `date /t` (cmd) or
`(Get-Date).ToString('yyyy-MM-dd')` (PowerShell) and use the result. Never guess or
hardcode a date.

**Order:** Prepend new entries at the top (below the H1 and first `---`). The file
reads newest-first.

**Amending vs. appending:** If your understanding of the decision evolves while the
same change is still staged (i.e., before the relevant git commit), edit the pending
entry in place to reflect the decision more accurately. Only append a new entry once
the prior decision is committed and you are recording something genuinely new.

**Immutability after commit:** Once an entry is committed, do not edit it -- even if
later work makes it stale. Later decisions that supersede an earlier one get their own
new entry at the top.

## Single source of truth / DRY

Logic that exists in more than one place will diverge. Strongly prefer one canonical
implementation and have other callers invoke it.

**Rules:**

- If the same PS logic appears in two scripts, extract it to a shared script and have
  both callers invoke it (e.g. via `Invoke-Command -FilePath`, dot-sourcing, or reading
  the file content in Python and sending it via WinRM). Do not keep parallel copies "in
  sync" manually.

- If a Python orchestrator (e.g. `run-prov-test.py`) needs to trigger something on a
  unit, it should invoke an existing `.ps1` script rather than embedding equivalent PS
  logic as a Python string. The PS file is the source of truth; Python is the caller.

- If a constant, path, or credential key is referenced in multiple places, define it
  once (e.g. in `vault/creds.json`, a shared PS module, or a Python constant) and
  import/read it everywhere. Do not hardcode the same value in multiple files.

- Before writing new logic, search for an existing implementation. If one exists,
  reuse or extend it. If you find duplication while working on something adjacent,
  fix the duplication as part of the same change rather than leaving it for later.

**Why:** This repo spans PowerShell scripts, Python orchestrators, and JSON configs
that all touch the same provisioning pipeline. Drift between copies has already caused
bugs (HTTP vs SMB transfer, hardcoded paths, stale credential keys). The cost of
finding and reusing existing code is always lower than the cost of debugging divergence.

## Shared utilities — use these, do not reimplement

Before writing any new PS or Python utility function, check whether it already exists
in one of the canonical shared files below. If a caller needs something the lib does not
yet provide, add it to the lib rather than defining it locally.

### PowerShell shared libs

| File | What it provides |
|------|-----------------|
| `server/lib/mast-log.ps1` | `Get-MastLog*` path helpers; `Now-Utc`; `Write-MastLog -Message -LogFile` |
| `client/mast-client-util.ps1` | `Disable-WindowsAutoUpdate` |
| `client/mast-invoke-child.ps1` | `Invoke-MastChildCommandLine`, `Import-MastCommandsFromJson` |

Dot-source pattern (two-path fallback so scripts work both from the repo and from staging):

```powershell
$_dot = Join-Path $PSScriptRoot 'mast-log.ps1'
if (-not (Test-Path $_dot)) { $_dot = Join-Path $PSScriptRoot '..\server\lib\mast-log.ps1' }
if (-not (Test-Path $_dot)) { throw "mast-log.ps1 not found" }
. $_dot
```

Scripts that need to run standalone (e.g. bootstrap on a USB drive) must use the soft-fail
variant (no `throw`) and keep a local fallback only for functions the lib may not be present
to supply.

### Python shared helpers (`vm/run-prov-test.py`)

| Helper | Purpose |
|--------|---------|
| `_ps_escape(s)` | Escape a string for embedding in a PS single-quoted string (`'` -> `''`). Never inline `.replace("'", "''")`. |
| `_find_unit_log_path(session, log_filename)` | Locate the newest session log on the unit. Never duplicate the embedded PS snippet. |
| `winrm_session(host, cred, read_timeout_s, op_timeout_s)` | Construct a `winrm.Session`. Never instantiate `winrm.Session` directly outside this factory. |

## `net use` argument order

`net use` is sensitive to argument position. The password **must** come immediately after
the UNC path and **before** any flags. Putting a flag (e.g. `/persistent:no`) between the
path and the password silently mis-parses and the mapping fails with no obvious error.

**Correct:**
```
net use Z: \\server\share <password> /user:<user> /persistent:no
```

**Wrong (causes silent failure):**
```
net use Z: \\server\share /persistent:no <password> /user:<user>
```

The canonical reference implementation is `client/mast-pull-staging.ps1`. Any new `net use`
call must match that argument order.

## Empty-string args are dropped from `module.json` `-File` commands

A `module.json` `command` / `verify` that passes an empty-string argument to a `-File`
script -- e.g. `-WeatherUrl ""` -- fails on the unit with **"Missing an argument for
parameter 'X'"**: the empty quotes collapse before PowerShell binds the parameter, so it
sees the flag with nothing after it. Omit the flag entirely when the value is empty and give
the param a default (`[string]${X} = ''`) instead; add the flag back only with a non-empty
value. (Hit while wiring the optional `-WeatherUrl` in the `desktop-shortcuts` provider.)

## Unit config: `C:\WIS\<role>.toml` + `MAST_PROJECT` (external-config epic)

The apps read a per-machine TOML bootstrap file at `C:\WIS\<role>.toml` (role = `MAST_PROJECT`,
e.g. `unit`) for machine identity + how to reach the config DB, and fail fast if it is missing.
The `config-bootstrap` provider (order 150) lays this down from `sites/<site>.toml` and sets
`MAST_PROJECT` machine-wide. **Site is selected explicitly via `build-mast.ps1 -Site`, never
derived from the hostname** -- do not reintroduce hostname->site parsing in providers. Per-site
profiles must match the controller's MongoDB `sites` doc (the app cross-checks them at startup).
The operator picks the site at bootstrap (`bootstrap-winrm.ps1`, default `ns`); it is persisted and
`onboard-mast-unit.ps1` writes it into the unit's `unit-registry.json` entry, which
`check-and-provision.ps1` passes to `build-mast.ps1 -Site`. Site is config-only -- never the hostname.

## Instrument profiles: PWI4 `.cfg` + PHD2 `.reg` (two stages)

**Stage 1 -- `instrument-profiles` provider (order 1850, after planewave/phd2/zwo):** lays down
TEMPLATES only. It injects the site location into `PWI4.cfg` from the **deployed `C:\WIS\unit.toml`
`[location]`** (written by config-bootstrap) -- not from `-Site` or the hostname -- and ships the
fleet-constant values verbatim (focuser `CountsPerMicron`, mount `ConnectionMethod=usb`, internal
IPs, equatorial). Because the per-user `mast` profile is not materialized at provisioning time,
artifacts stage to `C:\ProgramData\MAST\instrument-profiles` and apply (cfgs -> Documents, PHD2 ->
HKCU) via a one-shot `AtLogon` task on first `mast` logon. **No device->COM binding here.**

**Stage 2 -- `tools/calibrate-instruments.ps1` (post-hardware, operator-run, re-runnable -- BUILT + hardware-validated on mastw/mast00/mast02 2026-06-30):**
Run it as `mast` on a connected unit after the instruments are cabled. `-DryRun` reports without writing (safe even while PWI4 is open); a real run refuses if PWI4 is running (it rewrites its `.cfg` on exit). Preservation-safe: it only writes a `SerialPort` when the current value is empty or stale (points at an absent COM); a present-but-different COM is left alone unless `-Force`; `-EfaCom <COMx>` overrides when more than one generic adapter is present. It never touches focuser calibration, the pointing model, or mount-firmware tuning.
binds per-unit serial COM ports once instruments are connected. Cross-unit facts (mast00/02/w): the
**Elmo mount needs no COM** (PWI4 auto-detects it over USB everywhere); **PWBus OTA** = stable
`VID_1CBE/PID_0002` (auto-bindable); the **EFA focuser adapter brand VARIES** (FTDI vs Prolific) and a
cfg can point at an absent COM, so EFA needs operator confirmation / auto-detect -- never key it on a
fixed VID/PID; the **FCU/Standa stage** (`VID_1CBE/PID_0007`) is MAST_unit's and is auto-discovered by
libximc (`stage.py`), so it needs no recording. `tools/probe-instrument-detection.ps1` is the
read-only probe that dumps this map on a connected unit.

## Adding a new client script

When adding any new `client/*.ps1` that is needed at provisioning or bootstrap time:

1. **`build/build-mast.ps1`** — add a `Copy-Item` block so the file is staged into each
   unit's `01-provisioning/` folder.
2. **`vm/build-autounattend-iso.ps1`** — add a `Copy-Item` call in the staging block if the
   script is needed at bootstrap (i.e. used by `bootstrap-winrm.ps1` or `onboard-mast-unit.ps1`).

Skipping either step means the script is missing at runtime on the unit.

## Do not edit the staging area

Do **not** make edits to files under `staging/`. That directory is generated automatically by the build process and any manual changes will be overwritten.

Always make changes in the canonical source locations:
- Provider scripts: `server/providers/<name>/`
- Client scripts: `client/`
- Shared lib: `server/lib/`

## Staged assets must stay readable by the SMB pull account

`build-mast.ps1`'s `New-LinkOrCopy` hardlinks large assets into staging when elevated.
A hardlink shares the target file's single ACL, and the asset-cache sources have
inheritance off with no `mast-transfer` ACE - so without a fix the read-only SMB pull
account is denied on every staged binary and the unit's `robocopy` pull fails them all
(only the small copied files come through, ~58 KB). `New-LinkOrCopy` therefore runs
`icacls "<link>" /inheritance:e` after `mklink /H` so the link re-inherits the staging
dir's `mast-transfer:(RX)`. Do not remove it, and preserve `mast-transfer` read access
whenever you change how assets land in staging. Symptom to recognize: a pull that
copies small files but fails every binary is an ACL problem (check
`icacls <staged-binary>`), not a network/MTU/session issue. See DECISIONS 2026-06-28.

## Remotes: `upstream` is the integration repo, `origin` is the fork

`upstream` = `github.com/The-MAST-project/MAST_provisioning` (integration); `origin` =
`github.com/elibrody-weizmann/MAST_provisioning` (the working fork). "Fetch latest from
MAST_provisioning" means `git fetch upstream`, not `origin`. The working line is
`eli/vm-provisioning`, treated as the de facto main until the next milestone -- base new
work on it, and when comparing to `upstream/main` use the merge-base so the diff shows only
the real new contribution (a direct `HEAD..upstream/main` looks huge because of files we
added, not files upstream removed).

## Proxy mode is explicit (`--proxy-mode`)

A run's network mode is chosen by the operator, never auto-probed:
`python vm/run-prov-test.py --proxy-mode {weizmann,direct}` (default `weizmann`). The flag
flows through `build-mast.ps1 -ProxyMode` into `commands.json`. Running from off-campus (or
any unit that cannot reach `bcproxy.weizmann.ac.il:8080`) you MUST pass `--proxy-mode
direct`; otherwise every proxy surface is set to bcproxy and downstream installs fail.
On-campus, omit it (or pass `weizmann`). "dev vs prod" is a different axis from
on-/off-campus -- pick by the unit's network reachability only.

`-ProxyMode` governs only the network state *during* the run. Regardless of it,
`build-mast.ps1` appends an end-of-run finalize step (order 9000, with verify at
9001) that re-asserts the Weizmann bcproxy on all surfaces, so a unit always ships
proxy-ready -- a `direct` build flips to the proxy at the end, a `weizmann` build
re-asserts it idempotently. Nothing network-dependent runs after order 9000. See
DECISIONS.md 2026-06-25.

## WinINet installers behind bcproxy need the cert-revocation toggle

Behind bcproxy, Windows CryptoAPI revocation retrieval (cryptnet) fails (`0x80070057` ->
`CRYPT_E_REVOCATION_OFFLINE`), so WinINet installers that enforce server-cert revocation
(cygwin `setup-x86_64.exe`, the Chrome online stub) hard-fail TLS with WinINet error 12057.
git is unaffected (it does revocation best-effort). For any new WinINet-based online
installer behind the proxy, wrap it with `server/lib/mast-net.ps1`'s `Disable-` /
`Restore-WinINetCertRevocationCheck` (toggles HKCU `Internet Settings\CertificateRevocation`)
and restore afterward. Do not try to make cryptnet fetch revocation through bcproxy
(unsolved), and do not remove the internet dependency (git needs it).

## File encoding: BOM and cygwin line endings

- **PowerShell-authored JSON carries a UTF-8 BOM.** `build-mast.ps1` writes `commands.json`
  and `build-manifest.json` via `Out-File -Encoding UTF8`, which prepends a BOM
  (`EF BB BF`). Python readers MUST go through `vm_lib.load_json_file` / `parse_json_text`
  (BOM-tolerant), never `json.loads(path.read_text(encoding="utf-8"))`.
- **Files consumed by cygwin binaries need LF-only endings.** A config/list/script read by
  a cygwin program (e.g. `astrometry.cfg`) must be written with
  `[System.IO.File]::WriteAllText($path, $body, $enc)` using explicit `\n`, not
  `Set-Content` / `Out-File` (which emit CRLF on Windows). A trailing `\r` makes cygwin
  `opendir` / `open` fail silently (ENOENT on a path that visibly exists).

## Npcap is installed interactively; its provider is verify-only

The free Npcap installer's silent `/S` and feature flags are OEM-only -- the free build
ignores them and blocks on the NSIS options page, which can never be dismissed under a
Session-0 WinRM task. So Npcap is installed interactively by `client/bootstrap-winrm.ps1`
(full admin token), and the `npcap` provider only verifies the service/driver and
(re)registers the watchdog. Do NOT reintroduce installer-running logic into
`provide-npcap.ps1` or chase silent-flag / token / driver-trust fixes. To bump the version,
drop a new `npcap-*.exe` into `client/assets/`.

## Unwedge the dev VM's WinRM via SSH

The dev VM's WinRM listener occasionally wedges after repeated sessions -- the harness
connect then hangs in its WinRM wait loop. SSH is a separate service and stays reachable,
so restart WinRM over it: `vm_lib.SshSession(host, cred).run_ps('Restart-Service WinRM -Force')`
(this is what run-prov-test's SSH fallback rides on). Then WinRM connects again. Longer term
we may move the harness to SSH transport entirely.

## Do not write to git unless explicitly asked

Do **not** run `git commit`, `git push`, `git rm`, `git reset`, `git rebase`, `git lfs migrate`, `git filter-repo`, `git tag`, or any other history- or remote-mutating git operation **unless the user has specifically asked for it in the current request**. Read-only operations (`git log`, `git status`, `git diff`, `git show`, `git rev-parse`, `git ls-files`, `git lfs ls-files`, `git lfs migrate info`, `git fetch` of a read-only remote, etc.) are fine.

This applies even when an edit you just made feels "finished" and a commit looks like the obvious next step. Leave the working tree dirty and surface what you changed. Do not offer to commit "for tidiness"; wait to be asked.

When asked to commit/push, do exactly the scope requested. Do not fold in unrelated working-tree changes "while you're there", do not amend prior commits the user did not name, and do not push to remotes the user did not name.

**Why:** git history and remote state are the user's review surface. Premature commits force them to undo or amend; premature pushes can broadcast in-progress work, trigger CI, or move shared refs in ways collaborators see. The cost of a wasted commit/push is asymmetric -- doing it later when asked is cheap, undoing it after the fact is expensive.
