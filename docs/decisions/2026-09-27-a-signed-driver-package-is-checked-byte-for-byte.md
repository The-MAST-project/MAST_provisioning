---
decided: 2026-09-27
status: accepted
issue: MAST_provisioning#48
areas:
  - reproducibility
  - source-layout
---

# A signed driver package is checked byte for byte, not trusted to git's guess

**Why.** A provisioning run against mast03 on 2026-09-27 failed two modules, `zwo` and `intel-nic-driver`, both with the same error from `pnputil`:

> The hash for the file is not present in the specified catalog file. The file is likely corrupt or the victim of tampering.

A `.cat` is a **detached signature over the exact bytes** of every file in its package. `e2f.inf` and `ASICAMUSB3.inf` were stored with LF where the vendor signed CRLF, so the catalog could not match and Windows refused the whole package.

It had been that way since the files were first committed — 0 CR bytes at `9e5f136`, weeks before any of the line-ending work — and the first instinct, that the recent `.gitattributes` change caused it, was wrong. Nothing had ever installed these drivers through the provisioning path.

What kept it invisible is worth recording, because it is a property of the system and not an accident: `zwo` and `intel-nic-driver` execute only when they drift, and they almost never do. mast03's two runs before this one ran 15 commands each and touched neither. It took a 46-of-46 drift — every module targeted, so nothing excluded — to run them at all, and then both failed on a live unit rather than in a test.

**What.** The two `.inf` files are restored to CRLF. `pnputil /add-driver` then accepts both: `Added driver packages: 1`, exit 0. The Intel package reported no "(Already exists in the system)", which is the direct evidence that it had never been staged successfully before.

`*.dll` joins `*.inf`, `*.sys`, `*.cat` and `*.cer` in the `-text` block. Two package members are DLLs, and both happened to be safe only because they carry NUL bytes and git's binary heuristic spotted them. A signed package should not depend on a guess.

`server/prov/tests/test_driver_catalogs.py` is the guard those rules never had: for every directory holding a `.cat`, no member that git would treat as text may have LF without CRLF, and every member must actually resolve to `text=unset`. The second assertion is the one that matters over time — bytes being right today says nothing about the next person to touch the file. Verified by reverting `ASICAMUSB3.inf` to LF and watching it fail.

**Rejected.** *Re-signing the catalogs against the LF files*, which needs the vendor's key and is not ours to do. *Normalizing on the way out at build time*, which would make the repo's copy permanently wrong and put a rule in the build that has to be remembered rather than one in `.gitattributes` that cannot be forgotten. *Filing it as a separate change*: the run that found it was the one validating #48, the fix is small, and leaving a known-broken driver in the tree while the fix waited for its own review would have left the fleet in the state that caused this.

**Implications.** The catalog error is specific enough to recognise on sight, and the guard means it cannot come back silently. The wider lesson is the one the provisioning server keeps teaching: a module that rarely runs is a module whose failure mode is undiscovered, so anything that only executes on drift deserves a check that runs whether it drifts or not.
