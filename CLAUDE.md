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
