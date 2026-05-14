# MAST_provisioning — guidance for AI assistants

## Scripts must be ASCII-only

Do **not** introduce non-ASCII characters into executable scripts or modules under this repo (including inside comments and string literals).

Applies at minimum to: `*.ps1`, `*.psm1`, `*.py`, `*.sh`, `*.bat`, `*.cmd`.

**Why:** Windows PowerShell 5.1 often loads `.ps1` files using a legacy code page. UTF-8 sequences (smart punctuation, emoji, arrows, em dashes) can be mis-decoded and **break parsing** (unterminated strings, bogus errors far from the real line).

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

## Do not edit the staging area

Do **not** make edits to files under `staging/`. That directory is generated automatically by the build process and any manual changes will be overwritten.

Always make changes in the canonical source locations:
- Provider scripts: `server/providers/<name>/`
- Client scripts: `client/`
- Shared lib: `server/lib/`
