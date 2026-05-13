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

## Do not edit the staging area

Do **not** make edits to files under `staging/`. That directory is generated automatically by the build process and any manual changes will be overwritten.

Always make changes in the canonical source locations:
- Provider scripts: `server/providers/<name>/`
- Client scripts: `client/`
- Shared lib: `server/lib/`
