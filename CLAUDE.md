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

## Decision records (`docs/decisions/`)

Design rationale lives in **`docs/decisions/YYYY-MM-DD-slug.md`, one file per decision**.
The full format spec is `docs/decisions/README.md` -- read it before writing a record.

**The merged pre-2026-08-07 log is a FROZEN archive, kept whole**, at
`docs/decisions/archive-2026-05-04-to-2026-08-03.md` (91 entries, ending 2026-07-29). Do not
append to it and do not edit it. It stays authoritative for what it covers and is the
**only** place that rationale exists, so **search it alongside** the individual records.

**Its filename names its provenance, not its span.** As `DECISIONS.md` it ran to 2026-08-03;
the 27 entries written on `eli/provisioning-v3` and never merged to `main` were rewritten as
individual records on 2026-08-09, before that branch landed. The filename is unchanged so the
legacy citation mapping below keeps working. Why:
`docs/decisions/2026-08-09-unmerged-decisions-ship-in-the-current-format.md`.

**Legacy citations:** this file used to be `DECISIONS.md` at the repo root. About 30
comments and docs still say `see DECISIONS.md 2026-05-26` or `see the 2026-05-25 DECISIONS
entry` -- those all mean the archive above; the path in them is stale, the date is good.
They were deliberately not rewritten (a doc move is not worth touching 25 provider scripts).
Note that 19 of the archive's dates carry more than one entry (`2026-05-16` has eight), so a
bare date citation may be ambiguous -- read the surrounding entries, don't assume the first
match. A dated citation **after 2026-07-29** points at one of the extracted records, not at
the archive: list `docs/decisions/2026-0[78]-*.md` and match on the subject.

### Retrieval -- do this before changing unfamiliar code

When the question is *"why is this written this way?"* and the code does not answer it, the
rationale is very likely recorded. Look for it before assuming the shape is accidental:

```bash
git grep -il '<symbol, script, or path>' docs/decisions/   # covers records AND the archive
git log -1 --format=%s -- <path>          # then read the PR body the commit came from
ls docs/decisions/2*.md                   # filenames are descriptive slugs; this is the index
```

Do this in particular before "simplifying" something that looks redundant, removing a
workaround, widening a permission, or changing an ordering constant. Several such shapes in
this repo are deliberate and the reason is only in the record (`/persistent:no` on the `Z:`
mapping, the interactive Npcap install, the order-9000 proxy finalize).

**Report what you find, and treat it as history rather than law.** A record states what was
believed when the decision was made -- cite it with its date ("a 2026-08-03 decision chose
X because Y") and check whether the reason still holds, rather than treating it as a
standing prohibition. Standing prohibitions are in this file, not there.

### Writing a record

**When:** any change that embodied a judgment call -- a mechanism chosen over an
alternative, a constraint accepted, a compromise taken knowingly, an ordering with a
reason, or a bug whose *diagnosis* was surprising. The bar is deliberately low; the reader
is an agent, so volume is cheap and a missing record is expensive. Skip records only for
typos, mechanical renames, and refactors with no rationale.

**Anchor it in the prose.** Name the concrete file paths, script names, provider
directories, and symbol names **in the body**, spelled as they appear in the code -- that is
the only thing making a record findable from the code it explains. Keep identifiers out of
frontmatter: in a sentence about what was done on a date a stale path reads as history, but
in a metadata field it reads as a claim about the present. Frontmatter carries `areas:`
instead: 2-4 subject tags at any level of the system, **reused from
`docs/decisions/AREAS.md`** where one fits and **coined and added there** where none does.
Block list form only -- the inline `[a, b]` form drops out of that file's inventory command.

**Record the doubt.** The `Rejected` and `Unsettled` sections are the point -- alternatives
not taken (specifically enough to be recognized later), plus what was not known, knowingly
left broken, or assumed without verification. Do not write invariants or predictions about
what future contributors might do; if a decision produces a standing rule, add the rule to
this file and have it cite the record.

**Date:** always from a system command -- `date /t` (cmd) or
`(Get-Date).ToString('yyyy-MM-dd')` (PowerShell). Never guess. `decided:` is when the call
was made, not when the PR merges; git records the latter.

**Immutability:** the body of a record is never edited **once its `status:` is
`accepted`** -- the freeze binds on the flip, not on reaching `main`. To reverse or refine
such a record, write a new one with `supersedes:` set and flip the old one's `status:` to
`superseded` with `superseded_by:` filled (an archive entry has no slug, so name it in prose
instead). From that point exactly three frontmatter keys may be edited -- `status:`,
`superseded_by:`, `areas:` (the last so synonyms can be merged during `AREAS.md` curation).
The freeze protects the historical claim, not the navigation metadata. See
`docs/decisions/2026-08-16-a-record-freezes-when-accepted-not-when-merged.md`.

**While `proposed`, rewrite in place -- do not supersede.** A `proposed` record is freely
editable, body included, whether it sits on a branch or on `main`. If the decision changes
before it is accepted, the record is rewritten to state where it ended up: one record, no
correction file, no `superseded` status. The argument about how it moved lives on the PR and
on the record's `issue:`. An approach tried and abandoned during review usually belongs as a
`Rejected` entry in the rewritten record. See
`docs/decisions/2026-08-09-unmerged-decisions-ship-in-the-current-format.md`.

**A `proposed` record may merge ahead of its code** -- a design agreed as direction but
blocked or unbuilt. Three obligations come with it: `issue:` is **required** and its ticket
stays open until the flip; the landing PR **rewrites the body to what actually shipped**
(divergences into `Rejected`) before flipping to `accepted`; and only that rewritten form is
frozen. When reading one, treat every identifier in it as a name for something that **may not
exist yet** -- `git grep` the symbol before believing the code matches the account. The
standing list is `grep -l 'status: proposed' docs/decisions/2*.md`.

**A record lands in the repo whose code it decides.** `git grep` does not cross a clone
boundary, so a decision about another repo's symbols is unreachable from the code it
constrains no matter how well it is anchored. Keep a cross-repo design whole where the larger
share of the change is, and add a short citing record in each other affected repo -- or, until
those repos adopt the format, cite it from their `CLAUDE.md` or their issue.

## Every PR body states why, not just what

A PR body must contain a **Why** paragraph: the problem, what was tried or rejected, and
anything knowingly left undone. The *what* is already in the diff and the commit subjects;
the *why* exists nowhere else and is the thing that is impossible to recover three weeks
later when fixing a one-liner.

This is the second retrieval path: `git blame` -> commit -> PR -> rationale. It works from
any line of code and needs no index, which is why it is required on **every** PR, while a
`docs/decisions/` record is reserved for rationale that should outlive its diff.

Link the ticket (`Closes MAST_provisioning#NN`) and, when the change enacts one, the
decision record. The ticket carries the discussion; the PR carries the ratified reason.

> Provisional here, pending promotion to `mast-claude-config` -- PR conventions are
> genuinely cross-repo, and this is being proven on one repo first.

## Python is type-checked, and the checker is pyright

`basedpyright` (pyright plus a stricter default rule set) is a **blocking, green** CI job.
Config is `pyrightconfig.json` at the repo root; the version is pinned in
`requirements-dev.txt` beside `ruff`. Run it as `basedpyright` from the repo root — no
arguments, it reads the config. Pylance in VS Code reads that same file, so what the editor
shows is what CI enforces. Rationale, and why not mypy:
`docs/decisions/2026-08-17-pyright-not-mypy-for-the-python-server.md` (#87).

- **The suppression dialect is pyright's**, not mypy's: `# pyright: ignore[reportCallIssue]`,
  scoped to the rule. A bare `# type: ignore` still works but suppresses *everything* on the
  line, so don't reach for it. mypy-style `# type: ignore[arg-type]` codes are read as a
  blanket suppression — the bracket contents mean nothing to pyright.
- **Every suppression names why, and names its ticket if it is deferred work.** The waivers
  from the adoption are line-scoped for exactly this reason (see stage 2 of #87); do not
  widen a rule off in `pyrightconfig.json` to clear a finding.
- **Don't add `-> Any` or an unparameterized `dict` to quiet the checker.** Both re-blind
  every call site downstream, which is the state this repo was in before the adoption.
- **New code lands green.** The mode is `standard`; raising it is a separate argument, and
  `recommended` (2508 warnings here) is not the starting point.

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

### Python shared helpers (`server/prov/transport.py`)

The WinRM/SSH transport is the canonical `server/prov/transport.py` (lifted out of
`vm/vm_lib.py`, which now re-exports it and keeps only VBox test helpers). Import from
`prov.transport` in new server code; `vm/` scripts keep importing `vm_lib`.

| Helper | Purpose |
|--------|---------|
| `_ps_escape(s)` | Escape a string for embedding in a PS single-quoted string (`'` -> `''`). Never inline `.replace("'", "''")`. |
| `ps_lit(s)` | A value as a complete PS single-quoted literal. Use for every value interpolated into a remote command, not just the ones that look risky. |
| `local_address_for(peer_ip)` | This machine's address on the route to a unit, from the kernel. **Never send a unit this machine's name** (`COMPUTERNAME` / `gethostname()`) and never pick from the interface list — see the #70 record. |
| `pull_staging_args(...)` | The argument list for `client/mast-pull-staging.ps1`. The only place that names its parameters; both the driver and the `vm/` harness call it. Add a parameter there and here, never at a call site. |
| `connect_unit(host, cred)` | WinRM-preferred, SSH-fallback session to a unit. Prefer over `winrm_session` for real work. |
| `run_ps(session, script, ...)` | Run PS on a unit with heartbeat + hard timeout + resilient retry. |
| `winrm_session(host, cred, read_timeout_s, op_timeout_s)` | Construct a `winrm.Session`. Never instantiate `winrm.Session` directly outside this factory. |
| `load_json_object(path)` / `load_json_list(path)` | BOM-tolerant JSON read with the top-level shape asserted (`dict` / list-of-dicts), raising `TypeError` naming the path otherwise. **Prefer these over `load_json_file`**, which returns `object` and forces a narrow at every call site. |
| `UnitSession` | The type of a session to a unit — the union of `SshSession` and `winrm.Session`. **Annotate every session parameter with this**, never `winrm.Session` (which breaks `isinstance` narrowing — see the record) and never `Any`. |
| `UnitResponse` | What `run_ps` / `_resilient_run_ps` return, and what `check_rc` takes: the `status_code` / `std_out` / `std_err` protocol both transports' responses satisfy. Never annotate a shared path `winrm.Response`. |

### The server orchestration is Python (platform-agnostic)

The server-side control plane is the Python package **`server/prov/`**, driven by
`server/check_and_provision.py`. The PowerShell driver `server/check-and-provision.ps1`,
its Task Scheduler installer, and the five `server/lib` helpers only it dot-sourced were
**retired on 2026-08-16** — there is no PowerShell control plane to keep in step, and no
new server-side orchestration belongs in PowerShell. Rationale in
`docs/decisions/2026-07-12-port-server-orchestration-to-python.md` and
`docs/decisions/2026-08-16-the-powershell-driver-is-retired.md`. **Standing requirement: the provisioning server must be platform-agnostic — all
paths and mechanisms run end-to-end against the Windows units with no per-platform patching or
extra code.** Consequences for any new server code:

- **Remote/unit paths are literal strings** (`C:\MAST\...`, `\\server\share`), never `pathlib.Path`
  (Path mangles them on a non-Windows server). Only local server paths use `Path`/`os`.
- **Transfer is SMB for all platforms** (unit pulls via `net use`+robocopy; Samba serves the share
  on Linux). Don't add a non-SMB transfer path.
- **Read PS-written JSON BOM-tolerantly** (`transport.load_json_object` / `load_json_list` /
  `parse_json_text`); write plain UTF-8 + LF and rename atomically (`os.replace`).
- Resolve the PowerShell exe portably (`pwsh` on Linux, `powershell.exe` on Windows).
- On Windows, `zoneinfo` needs the `tzdata` pip package (else IANA tz ids fall back to server-local).
- The steps the driver *drives* stay PowerShell (`build-mast.ps1`, `mast-pull-staging.ps1`,
  `execute-mast-provisioning.ps1`, providers) — invoke them, don't rewrite them.

Test the package with `.venv/bin/python -m pytest server/prov/tests`. Directional (not yet
committed): SSH-first transport (see #6) and a UTF-8-no-BOM JSON standard.

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

## `Z:` is the unit's operational drive -- provisioning does not claim it

`Z:` means exactly one thing on a MAST unit: the site controller's share,
`\\<controller_host>\mast-share`. MAST_common's `Filer` roots its "shared" area on
`Z:\MAST\<hostname>\`, the ram-to-shared mover writes every exposure there, and when the
letter is missing `Filer` **silently** substitutes `C:\MAST`. Provisioning must never map
`Z:` to anything of its own; reach the provisioning server's `mast-shared` by **UNC**.

Two rules follow for any code that touches a network drive on a unit:

- **Map in the session that will use it.** Drive letters are per-logon-session. The MAST
  services run as **LocalSystem** (nssm, no `ObjectName`), so a mapping made by
  provisioning (the autologon `mast` user) is invisible to them. The single place that
  establishes `Z:` is the `mast-shared-mount` provider, via a SYSTEM scheduled task plus
  an nssm `Start/Pre` hook on `mast-unit`.
- **Do not infer a host from a drive mapping.** `Z:` points at the controller, not the
  provisioning server -- deriving one from the other lands on the wrong machine (this
  was a real fallback in the timesync provider).

See `docs/decisions/2026-08-03-z-belongs-to-the-operational-share.md` and issue #25.

## Empty-string args are dropped from `module.json` `-File` commands

A `module.json` `command` / `verify` that passes an empty-string argument to a `-File`
script -- e.g. `-WeatherUrl ""` -- fails on the unit with **"Missing an argument for
parameter 'X'"**: the empty quotes collapse before PowerShell binds the parameter, so it
sees the flag with nothing after it. Omit the flag entirely when the value is empty and give
the param a default (`[string]${X} = ''`) instead; add the flag back only with a non-empty
value. (Hit while wiring the optional `-WeatherUrl` in the `desktop-shortcuts` provider.)

## Unit config: `C:\WIS\config.toml` + `machine_role` (external-config epic)

The apps read a per-machine TOML bootstrap file at the fixed path `C:\WIS\config.toml` for
machine identity + how to reach the config DB, and fail fast if it is missing. The machine's
role is the required `machine_role` field inside the file (`unit`/`spec`/`control`) -- there is
no `MAST_PROJECT` environment variable. The `config-bootstrap` provider (order 150) writes the
file from `sites/<site>.toml` with `machine_role` injected as a top-level key. **Site is selected
explicitly via `build-mast.ps1 -Site`, never
derived from the hostname** -- do not reintroduce hostname->site parsing in providers. Per-site
profiles must match the controller's MongoDB `sites` doc (the app cross-checks them at startup).
The operator picks the site at bootstrap (`bootstrap-winrm.ps1`, default `ns`); it is persisted and
`onboard-mast-unit.ps1` writes it into the unit's `unit-registry.json` entry, which
the driver passes to `build-mast.ps1 -Site`. Site is config-only -- never the hostname.

## Instrument profiles: PWI4 `.cfg` + PHD2 `.reg` (two stages)

**Stage 1 -- `instrument-profiles` provider (order 1850, after planewave/phd2/zwo):** lays down
TEMPLATES only. It injects the site location into `PWI4.cfg` from the **deployed `C:\WIS\config.toml`
`[location]`** (written by config-bootstrap) -- not from `-Site` or the hostname -- and ships the
fleet-constant values verbatim (focuser `CountsPerMicron`, mount `ConnectionMethod=usb`, internal
IPs, equatorial). Because the per-user `mast` profile is not materialized at provisioning time,
artifacts stage to `C:\ProgramData\MAST\instrument-profiles` and apply (cfgs -> Documents, PHD2 ->
HKCU) via a one-shot `AtLogon` task on first `mast` logon. **No device->COM binding here.**

**Stage 2 -- `tools/calibrate-instruments.ps1` (post-hardware, operator-run, re-runnable -- BUILT + hardware-validated on mastw/mast00/mast02 2026-06-30):**
Run it as `mast` on a connected unit after the instruments are cabled. `-DryRun` reports without writing (safe even while PWI4 is open); a real run refuses if PWI4 is running (it rewrites its `.cfg` on exit). Preservation-safe: it only writes a `SerialPort` when the current value is empty or stale (points at an absent COM); a present-but-different COM is left alone unless `-Force`; `-EfaCom <COMx>` overrides when more than one generic adapter is present. It never touches focuser calibration, the pointing model, or mount-firmware tuning. Operators normally run it via the **"MAST Instrument Calibration" desktop shortcut** (`-Interactive` menu: view state / dry run / apply / force, showing the diff and prompting to close PWI4). The tool lives in the `instrument-profiles` provider, which deploys it to `C:\ProgramData\MAST\instrument-profiles\calibrate-instruments.ps1`; the `desktop-shortcuts` provider creates the launcher.
binds per-unit serial COM ports once instruments are connected. Cross-unit facts (mast00/02/w): the
**Elmo mount needs no COM** (PWI4 auto-detects it over USB everywhere); **PWBus OTA** = stable
`VID_1CBE/PID_0002` (auto-bindable); the **EFA focuser adapter brand VARIES** (FTDI vs Prolific) and a
cfg can point at an absent COM, so EFA needs operator confirmation / auto-detect -- never key it on a
fixed VID/PID; the **FCU/Standa stage** (`VID_1CBE/PID_0007`) is MAST_unit's and is auto-discovered by
libximc (`stage.py`), so it needs no recording. `tools/probe-instrument-detection.ps1` is the
read-only probe that dumps this map on a connected unit.

## MAST services: `mast-` naming + manual start (current dev stage)

The MAST NSSM services are named with a `mast-` prefix for findability: `mast-unit`,
`mast-pwi4`, `mast-pwshutter`, `mast-phd2`. Each is registered by its own provider
(`mast`, `planewave`, `phd2`) as **auto-start** and started, so per-provider verification and
the diagnostics/validation steps run against live services. The **`mast-services-finalize`
provider (order 9500)** is the last operational step (after all validation and the 9000 proxy
finalize, before 9999 reboot detection): it sets every present MAST service to **manual** and
stops them, so a provisioned unit does not auto-raise telescope services on boot. The canonical
service-name list lives once in `server/providers/mast-services-finalize/mast-service-names.ps1`
(shared by the provider and its verify). To migrate an already-provisioned unit to the new
names + manual policy, use `tools/rename-mast-services.ps1` (self-contained, idempotent,
`-DryRun`-able) via `run-remote-script-winrm.py`.

**Manual start is a deliberate current-development-stage measure**, not the end state: once the
services are battle-tested (a future stage, months out) we intend to restore automatic start,
at which point `mast-services-finalize` is expected to be removed or relaxed. If you touch a
service name, update it in the registering provider, the name references
(`verify-planewave.ps1`, `diagnostics/verify-diagnostics.ps1`, `mast-unit`'s `AppDependencies`),
`mast-service-names.ps1`, and `tools/rename-mast-services.ps1`. See DECISIONS.md 2026-07-01.

## Adding a new client script

When adding any new `client/*.ps1` that is needed at provisioning or bootstrap time:

1. **`build/build-mast.ps1`** — add a `Copy-Item` block so the file is staged into each
   unit's `01-provisioning/` folder.
2. **`vm/build-autounattend-iso.ps1`** — add a `Copy-Item` call in the staging block if the
   script is needed at bootstrap (i.e. used by `bootstrap-winrm.ps1` or `onboard-mast-unit.ps1`).

Skipping either step means the script is missing at runtime on the unit.

## `--host-unit` is a machine, and `mastw` is a real telescope

`vm/run-prov-test.py` installs software on whatever `--host-unit` resolves to. Two of
its flags read alike and are not:

- **`--host-unit`** -- the machine to connect to and provision. For the dev cycle this
  is the VirtualBox VM, which is on the host-only network with **no DNS record**, so
  it is addressed by IP. Read the current one from `VBoxManage guestproperty enumerate
  mast-unit` (`Net/0/V4/IP`); it is a DHCP lease and does change.
- **`--hostname`** -- only the identity the payload is *built* for. The VM stands in
  for `mastw`, so `--hostname mastw` is correct even though the VM answers to its own
  name.

**Never pass a bare unit name to `--host-unit`.** Unit names resolve through institute
DNS to real machines, and one of them is a prototype attached to a real telescope, so a
"dev" cycle aimed there provisions it. This is not hypothetical: on 2026-08-17 two runs
took a bare name from the harness's own usage example and reached that prototype,
stopping only because the SMB mount failed. The examples now carry a placeholder;
resolve any name you did not read off the VM before using it.

The same care applies to the driver: `--only-hosts` names entries in
`server/unit-registry.json`, and every name in it is a real machine.

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

## Remotes: a single `origin`, the integration repo

`origin` = `github.com/The-MAST-project/MAST_provisioning` and there is no second remote.
"Fetch latest from MAST_provisioning" is plain `git fetch`. The `elibrody-weizmann` fork
was retired on 2026-08-02 after its last unmerged content landed upstream; if you find a
checkout still carrying `origin` = fork plus `upstream` = The-MAST-project, it predates
that change -- `git remote remove origin && git remote rename upstream origin` brings it
into line.

The working line is `main` (the v1+v2 provisioning epics merged there via PR #9). Base new
work on `origin/main` and branch per topic; there is no long-lived de facto trunk sitting
off to the side any more.

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

## Unwedge a unit's WinRM via SSH (dev VM and real units)

Both the dev VM and real units (e.g. mast02) hit this: the WinRM listener wedges after
repeated sessions, or is simply down after a boot -- the harness connect then hangs in its
WinRM wait loop / `run-remote-script-winrm.py` reports "TCP 5985 not open". SSH is a separate
service and stays reachable, so restart WinRM over it:
`vm_lib.SshSession(host, cred).run_ps('Restart-Service WinRM -Force')` (this is what
run-prov-test's SSH fallback rides on). Then WinRM connects again.

**But a service restart does NOT guarantee reachability across subnets.** Windows' built-in
"Windows Remote Management (HTTP-In)" firewall rule is scoped to `RemoteAddress = LocalSubnet`
(the default, notably for the Public profile). So when the caller is on a different subnet than
the unit (e.g. the prov workstation on the campus network calling a unit on its site VLAN),
5985 stays refused even though the listener is up and bound locally -- while SSH (port 22,
scoped Any) keeps working.
Confirm with `Test-NetConnection <unit> -Port 5985` vs `-Port 22` from the caller.

**Do NOT "fix" this by widening the WinRM rule to the whole network** (`-RemoteAddress Any`) --
exposing WinRM fleet-wide is the wrong security posture. The correct direction is to run the
work over **SSH transport** instead: `vm_lib.SshSession(...).run_ps(...)`, uploading any script
via the session's SFTP channel (`_client.open_sftp().put(...)`). This is how
`tools/rename-mast-services.ps1` was run against mast02 when its WinRM was unreachable
cross-subnet. Longer term the harness is expected to move to SSH transport entirely; prefer SSH
over opening WinRM.

Gotcha when capturing `nssm get` output over any transport: nssm.exe writes **UTF-16LE** to
stdout, so a naive PowerShell capture yields interleaved NULs (`C\0:\0\\0P\0...`). Strip them
with `-replace "`0", ''` before using the value (see `tools/rename-mast-services.ps1`).

## Do not write to git unless explicitly asked

Do **not** run `git commit`, `git push`, `git rm`, `git reset`, `git rebase`, `git lfs migrate`, `git filter-repo`, `git tag`, or any other history- or remote-mutating git operation **unless the user has specifically asked for it in the current request**. Read-only operations (`git log`, `git status`, `git diff`, `git show`, `git rev-parse`, `git ls-files`, `git lfs ls-files`, `git lfs migrate info`, `git fetch` of a read-only remote, etc.) are fine.

This applies even when an edit you just made feels "finished" and a commit looks like the obvious next step. Leave the working tree dirty and surface what you changed. Do not offer to commit "for tidiness"; wait to be asked.

When asked to commit/push, do exactly the scope requested. Do not fold in unrelated working-tree changes "while you're there", do not amend prior commits the user did not name, and do not push to remotes the user did not name.

**Why:** git history and remote state are the user's review surface. Premature commits force them to undo or amend; premature pushes can broadcast in-progress work, trigger CI, or move shared refs in ways collaborators see. The cost of a wasted commit/push is asymmetric -- doing it later when asked is cheap, undoing it after the fact is expensive.

## Project-wide LLM guidance

Cross-repo LLM guidance for MAST lives in the **`mast-claude-config`** repo (`github.com/The-MAST-project/mast-claude-config`) -- the overarching home for project-wide instructions (shared coding standards, team working-style, global environment facts), deployed into `~/.claude/` by its `setup.sh`. Keep repo-specific guidance in this file; put genuinely cross-repo guidance there. See `mast-claude-config/CLAUDE.md` for what belongs where.
