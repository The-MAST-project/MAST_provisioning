---
decided: 2026-09-17
status: accepted
issue: MAST_provisioning#216
areas:
  - reproducibility
  - drift
  - static analysis
---

# .gitattributes decides line endings, so a payload's bytes follow from the commit

**Why:** two working trees on the provisioning server, at the same commit `dd4d16f`, both reporting `git status` clean, built different payloads:

```
C:\Users\labcomp2\Desktop\MAST\MAST_provisioning   payload_hash=680fef8a…   needs-update=46
C:\agent-worktrees\2026-09-14-relay\...            payload_hash=8e6a74d0…   needs-update=1
```

Diffing the two `payload-manifest.json` files: the same 542 paths, **113 with different bytes**, every one a text file. One tree held LF, the other CRLF.

Two git installations sit on that machine's `PATH` and disagree — cygwin git 2.51.0 with `core.autocrlf` unset, Windows git 2.54.0 with it `true` from its own system gitconfig. With no `text` attribute for `.ps1` and the rest, nothing arbitrated: whichever tool performed the clone decided the working tree's line endings. The repository itself stores LF for 364 of its 366 text blobs, so the LF tree was the faithful one; the two exceptions were a decision record and `server/providers/jupyter/assets/requirements.txt`, committed from a CRLF tree by accident.

`git status` cannot see this, and that is the part worth remembering. Git's stat cache skips the content comparison when a file's size and mtime match the index entry, so a tree can diverge from its own commit and go on reporting clean indefinitely. Both trees did.

**What:** `.gitattributes` now opens with `* text=auto eol=lf`, placed **first** so the existing `-text` rules for LFS assets still win — the last matching rule takes precedence. Driver INFs, catalogs, `.sys` and certificates are marked `-text` explicitly: they reach a unit byte for byte and must not be rewritten by a filter whatever git guesses about them. The two accidental CRLF blobs were renormalized.

`server/prov/tests/test_payload_byte_determinism.py` holds it: no tracked file may carry CRLF into the index, every text file must have a rule rather than leaving the decision to the tool, and the byte-exact suffixes must resolve to `text: unset`.

**Rejected:** *setting `core.autocrlf=false` on the build host.* It fixes one machine and not the property — the next clone, the next host, or a checkout by the other git reintroduces it. Attributes travel with the repository, which is what makes them the answer. *Normalizing only `.ps1`.* The 113 differing files included `.json`, `.cmd` and `.inf`; enumerating extensions is how `.sh` came to be the only rule in the first place (#214), and the gap is the general case.

**Unsettled:** this makes future checkouts deterministic and does **not** repair existing trees. Anything already checked out CRLF stays CRLF until re-checked-out or renormalized, and keeps reporting clean while it does. The provisioning server's canonical clone was normalized by hand on 2026-09-17; the task worktrees on it were not.

Nor does this close the detection half. `server/lib/mast-git-currency.ps1` establishes which *commit* a clone is on and exists because of #177 — *"the check written to catch a stale checkout could not see the case that produces one."* This is that failure one level down: the revision is checked and the bytes are not. A content-level assertion needs `git update-index --refresh` before comparing, or the stat cache defeats it exactly as it defeated `git status` here.

**Implications:** the first fleet run from a normalized tree will legitimately re-install 113 files on every unit — real drift, caused by the tooling rather than by any change anyone made. Worth expecting rather than investigating.
