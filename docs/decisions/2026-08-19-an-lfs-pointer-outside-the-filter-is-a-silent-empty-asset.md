---
decided: 2026-08-19
status: accepted
issue: MAST_provisioning#101
areas:
  - reproducibility
  - failure reporting
  - bootstrap
---

# An LFS pointer outside the filter is a silent, empty asset

**Why:** `client/assets/npcap-1.88.exe` was committed as a git-LFS pointer, and `.gitattributes` did not cover the path. The rules are per-directory — `server/providers/*/assets/*.{zip,exe,tgz,msi,whl,vsix}`, plus a global `*.iso`, `*.msi`, `*.whl` — and `client/assets/` matched none of them:

```
$ git check-attr filter -- client/assets/npcap-1.88.exe
client/assets/npcap-1.88.exe: filter: unspecified
```

Without the filter attribute, checkout writes the pointer **text** into the working tree. Every clone therefore held a 132-byte file (135 with CRLF) where a 1,320,424-byte installer belonged — confirmed on two independent clones, this repo's on the Mac and the provisioning server's. `vm/build-autounattend-iso.ps1` stages that file onto the unit ISO and `bootstrap-winrm.ps1` runs it, so from a fresh clone both would have shipped and executed a 132-byte "installer".

Nothing anywhere reported a problem. The step that should have caught it is the one that hides it:

```
$ git lfs pull --include="client/assets/npcap-1.88.exe"
$ echo $?
0
```

LFS exits 0 on a path it does not filter, because from its point of view there is nothing to do. A missing asset presents as a successful command and a file that exists.

**What:** one rule, `client/assets/*.exe filter=lfs diff=lfs merge=lfs -text`, and a re-checkout. The stored object was never the problem — GitHub's LFS batch API returns a download action for oid `a2f4ec1e5ea353ff67efd24b2ebf081ba44532410fae8d5e146af0310aa4f56b`, so only the smudge was missing. With the rule in place `git checkout` produces the real PE32 NSIS installer at the matching SHA256, and `git status` stays clean: the clean filter turns the binary back into the identical pointer, so no content was re-committed.

A sweep of every path `git lfs ls-files` reports, checking each against `git check-attr filter`, found this as the only stranded one; the other 43 resolve `filter: lfs`.

**Rejected:**

- **Re-committing the binary as a plain (non-LFS) blob.** The first diagnosis was that the object had never been pushed, which would have made this the only way to restore it — and the recovered copy was in hand, taken from a leftover `%TEMP%\autounattend-stage-<guid>\` on the provisioning server and verified against the pointer's own oid. Querying the LFS batch API before acting showed the object present on the server, which made the whole idea unnecessary. It would also have put one vendored binary on a different footing from the other 43 for no reason.
- **A broad `**/*.exe` rule.** It would close this bug class for good, but it also sweeps in any future executable anywhere in the tree, including ones deliberately kept as ordinary files. The per-directory list stays explicit; the comment on the new rule says a new asset directory needs its own line, which is the actual recurrence risk.

**Unsettled:**

- **Nothing detects the next one.** This was found by hand while staging a bootstrap USB, not by any check. A CI step comparing `git lfs ls-files` against `git check-attr filter` is about four lines and would have caught it at the commit that introduced it — not done here, because the fix and the guard are separate changes and only one of them was asked for.
- **The recurrence risk is structural.** As long as the rules are per-directory, an asset landing in a new directory is unprotected by default, and the failure is silent. `#48` (a versioned asset store) is the standing proposal that would replace this arrangement rather than patch it.
- **How long the working trees have been carrying the real file** is unknown. The pointer dates to the npcap commit; the machines that build ISOs evidently had the binary at some point, which is why no unit has been bootstrapped with a broken installer. Nothing establishes when that stopped being true for a fresh clone.
