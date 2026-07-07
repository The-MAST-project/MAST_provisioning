# Making Chrome the default browser: analysis and options

**Status:** investigated 2026-07-01. **Decision (2026-07-02): REJECTED -- not automated.** Provisioning does not attempt to set the default browser; the OS default stands and operators use Chrome via shortcuts (and can set it default themselves if they wish). Rationale below. Kept as the durable record so this is not re-attempted.

This note captures why an apparently trivial backlog item ("make Chrome the default browser") is not trivial on Windows 10/11, what we found on a real unit, the options with their trade-offs, and how it reframes a couple of other, already-shipped provisioning tasks.

---

## 1. Plain-language summary (for the non-Windows-internals reader)

Windows deliberately makes it hard for software to silently change your default browser -- that used to be a favourite malware/adware trick, so since Windows 8 the "which app opens web links" choice is sealed with a per-user cryptographic signature ("UserChoice hash") that only Windows itself can produce, and only in response to a person clicking in the Settings UI.

Our provisioning runs as the machine (SYSTEM) and cannot produce that signature. The freshly-provisioned `mast` operator account **already has** a default (Windows seeds it to Internet Explorer/Edge the first time the account logs in), so there is no "blank slate" we can fill in from a script.

That leaves only three ways to end up with Chrome as the default, none of them a clean "set it in a script during provisioning":
- forge the signature with a reverse-engineered tool (unofficial, can break on any Windows update),
- declare defaults the Microsoft-sanctioned way, but that only works when the account is **first created** (before bootstrap has already logged `mast` in), or
- **have the operator click "set default" once** on the unit (the normal, supported flow).

Because these machines control a telescope and always have an operator, the safest option is the operator click -- which makes this a one-line setup step, not automation. Hence the lean toward not building it into provisioning.

---

## 2. What we were asked to do

Backlog item (MAST_provisioning#5): *"Make Chrome the default browser in the `chrome` module, so operator `.url` shortcuts open in Chrome. Account-agnostic HKLM ProgID for `http`/`https`/`.htm`/`.html` (same approach as the DS9 `.fits` association), so it applies to the autologin `mast` profile that has no per-user UserChoice yet. Add a verify check."*

The stated approach assumes the `mast` profile has **no per-user UserChoice** for the browser. That assumption turned out to be false.

## 3. How Windows resolves a file/URL association

Two layers, checked in this order for the current user:

1. **Per-user `UserChoice`** (highest priority):
   - files: `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\<ext>\UserChoice`
   - protocols: `HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\<scheme>\UserChoice`
   - Each holds a `ProgId` (the chosen handler) **and** a `Hash`. Windows recomputes the hash on every use; if it does not match, the `UserChoice` is treated as tampered and **ignored** (Windows falls back, and often resets it).
2. **Machine-wide `HKLM\Software\Classes`** fallback (used only when there is **no** `UserChoice` for that type). This is the layer the DS9 `.fits` association writes, and the layer the backlog item intended to use.

**Key rule:** the HKLM fallback is authoritative **only when no `UserChoice` exists** for that extension/protocol.

## 4. The `UserChoice` hash (why silent setting is blocked)

The `Hash` is an anti-hijacking seal introduced in Windows 8. It is a keyed hash (MD5 + a proprietary mixing) computed over: the extension/protocol, the **user's SID**, the `ProgId`, the registry key's last-write timestamp, and a fixed salt string baked into the shell. Because it is bound to the user's SID and the algorithm is undocumented, only the Windows shell -- acting as that user, through the trusted Settings UI -- can normally produce a valid one.

Consequences:
- Writing `ProgId = ChromeHTML` without a valid `Hash` does nothing; Windows rejects it.
- A valid hash **must be computed as the target user** (mast's SID) -- provisioning's SYSTEM context cannot do it directly.
- The algorithm is only known via **reverse-engineering** the Windows shell binaries (documented publicly by Christoph Kolbicz / SetUserFTA and reproduced in open-source PowerShell/C# ports). Microsoft can change it in any update and silently break every forging tool until it is re-reverse-engineered.

### How an app's own "Make this browser default" button works
On Windows 10/11 the browser **cannot** set it. "Make default" calls into Windows (`LaunchAdvancedAssociationUI` / opens `ms-settings:defaultapps`) which **opens the Settings page**; the **user** confirms, and then **explorer.exe writes the valid hash as that user**. The app only requests the UI. `chrome.exe --make-default-browser` does exactly this on Win10/11 (it opens Settings; it does not set anything itself).

## 5. What we found on a real unit (mast02)

Probed read-only as the actual `mast02\mast` autologin account:

```
.html  UserChoice = 'IE.AssocFile.HTM'     <- mast profile ALREADY has a choice
http   UserChoice = 'IE.HTTP'              <- mast profile ALREADY has a choice
HKLM http/https   = iexplore.exe %1        (machine fallback, currently IE)
Chrome installed  = yes (ChromeHTML ProgId present, points at chrome.exe)
```

So the `mast` profile **already has a per-user UserChoice** for the browser (Windows seeded it to IE). Nobody set that deliberately -- the OS creates a browser `UserChoice` on its own at first logon. Therefore the HKLM fallback is overridden and the backlog item's approach cannot work.

### Why this happens (the reframe)
Bootstrap **creates the `mast` user and requires a reboot for it to take effect**, so by the time provisioning runs, `mast` **exists and is logged in** -- and thus already has its browser `UserChoice`. There is **no hash-free "first association" window** for the browser on a real, logged-in profile: the OS has already made the choice.

Contrast `.fits`: Windows never auto-assigns `.fits`, so mast has **no** `.fits UserChoice`, and the HKLM fallback legitimately governs. That is why the DS9 pattern works for `.fits` but not for the browser.

## 6. Options and trade-offs

| Option | Mechanism | Works on existing mast profile? | Trade-offs |
|--------|-----------|-------------------------------|------------|
| **HKLM fallback** (the backlog item's plan) | Write `HKLM\Software\Classes` -> Chrome | **No** -- overridden by mast's existing UserChoice | Would also make `verify` falsely pass (checks HKLM keys, not the effective default). Rejected. |
| **A. Forge the hash** | SetUserFTA.exe or a pure-PowerShell port, run **as mast** via an AtLogon task | Yes | Depends on an **undocumented, reverse-engineered** algorithm; can break on a Windows update. Binary variant adds a closed-source `.exe` on the telescope PCs; PS variant is auditable but still forges the seal. |
| **B. Delete UserChoice + HKLM fallback** | Remove mast's `UserChoice` for http/https/.htm/.html (as mast), rely on HKLM -> Chrome | Partially | Windows tends to re-seed a browser UserChoice; can trigger a one-time "How do you want to open this?" prompt. Non-deterministic. |
| **C. DISM / GP default-associations XML** | `Dism /Online /Import-DefaultAppAssociations` or the GP "default associations configuration file" | **No** for the existing mast profile -- only applies when a profile is **created** | The Microsoft-sanctioned path (Windows writes valid hashes itself). Would have to move **into bootstrap/base image, before the mast profile is first created** -- a structural change, not a `chrome`-provider change. |
| **D. Prompt the operator on first login** | AtLogon-as-mast one-shot runs `chrome.exe --make-default-browser` (opens Settings) + an instruction; operator clicks once | Yes | The only fully-supported, future-proof path (the shell writes the correct hash). **Attended** -- cannot be forced; if dismissed, Chrome is not default. Turns this into an operator procedure, not automation. |

## 7. Audit of related, already-shipped tasks (reframe check)

- **DS9 `.fits` association** -- mechanism is **sound**: mast has **no** `.fits`/`.fit`/`.fts` UserChoice, so the HKLM fallback governs. Caveat: on mast02 today `.fits -> Fits.File` (ASI Studio) and `SAOImageDS9.fits` has no command, i.e. the DS9 association is **not currently applied** there (mast02 predates that code). A re-provision would set it. No code change needed; it is a `pending re-provision` item on mast02.
- **instrument-profiles first-logon apply** -- the AtLogon-as-mast task is **still correct**. Its real justification is that providers run in **SYSTEM context** and cannot write mast's HKCU directly; that holds regardless of whether the hive exists. Only the "profile not materialized yet" half of the original rationale was inaccurate.
- **General principle to remember:** `HKLM\Software\Classes` is a valid default **only** for associations with no per-user `UserChoice`. For anything Windows auto-assigns at first logon (notably the browser), `UserChoice` wins and must be set as the user -- which on Win10/11 means either forging the hash or an operator click.

## 8. Recommendation

Automating a **default browser** on Windows 10/11 is fundamentally at odds with the OS's anti-hijacking design once the profile exists. The realistic outcomes are:
- **Reject / accept the OS default** -- do nothing in provisioning; operators use Chrome via shortcuts, and can set it default themselves if they want. Lowest cost, no fragility.
- **Option D (attended prompt)** -- if a Chrome default is genuinely wanted, implement it as an AtLogon prompt + a "Set Chrome as Default" desktop shortcut, and record the one click as a step in the field-findings note. Supported and future-proof, but explicitly a manual step.

Options A (forge) and B (delete) are not recommended for machines that control hardware: A is fragile against Windows updates and (in binary form) adds a closed-source tool; B is non-deterministic. Option C is the sanctioned automated path but requires moving default-association handling into bootstrap **before** the mast profile is created -- a larger change than this item warrants.

## 9. Decision

**REJECTED (2026-07-02).** We do not automate the default browser. The OS default stands; operators
open Chrome via the provided shortcuts and may set it as their default themselves. This avoids
depending on a forged, undocumented hash (fragile across Windows updates) or a closed-source tool on
telescope PCs, and avoids restructuring bootstrap for the DISM/GP path.

If a Chrome default is ever genuinely required, the **only** supported path is **Option D** -- an
attended first-login prompt (`chrome.exe --make-default-browser` opens the Settings page) plus a
"Set Chrome as Default" desktop shortcut -- implemented as a documented **operator step**, not silent
automation. Do not reintroduce the `HKLM\Software\Classes` approach for the browser (it is overridden
by the mast profile's existing `UserChoice`; see above).
