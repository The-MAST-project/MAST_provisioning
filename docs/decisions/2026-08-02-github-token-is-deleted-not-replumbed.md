---
decided: 2026-08-02
status: accepted
issue: MAST_provisioning#17
areas:
  - credentials
  - source-layout
  - providers
---

# The GitHub token is deleted, not re-plumbed

**Why:** `provide-mast.ps1` cloned with a PAT embedded in the remote URL
(`https://x-access-token:<tok>@github.com/...`), read from a `mast_github.txt`
staged into the payload. That left a live secret in plaintext in every
provisioned unit's `.git/config`, and one copy of the token file per run under
`C:\mast-staging\<run-id>\` -- issue #17. Every repo the module clones is now
**public** (verified 2026-08-02 across all seven The-MAST-project repos), and
`provide-mast.ps1` was the token's only consumer, so the credential is not
needed by anything.

**What:** Removed the credential rather than managing it better. Gone:
`Get-MastGitHubHttpsCloneUrls` and the token read in `provide-mast.ps1` (clones
are anonymous HTTPS via a plain `Get-MastGitHubCloneUrl`); the
`vault\tokens\mast_github.txt` staging copy, the `-AllowMissingGithubToken`
switch and its `-TestMode` optional-payload exception in `build-mast.ps1`; the
switch at all three call sites (`check-and-provision.ps1`, `prov/driver.py`,
`vm/run-prov-test.py`); and the setup step, vault-tree entry and requirements
Exception #3 / row 12 in the docs. The `.gitignore` rules for the token are
deliberately **kept** as a guard against re-introduction.

**Rejected:**

- **Re-plumbing the token more safely** -- a credential helper, an
  `url.<...>.insteadOf` rewrite, or a DPAPI blob like the SMB password. All were
  available and all were rejected for the same reason: the repos are public, so the
  best handling of this secret is not to have one. Managing a credential nothing
  needs is pure attack surface.
- **Rotating the token and leaving the mechanism in place.** Rejected as fixing the
  instance rather than the class; the plaintext copy in every unit's `.git/config`
  would simply hold a newer secret.
- **Scrubbing the token from the units' existing `.git/config` by hand.** Considered
  and superseded within the issue: the stage-6 migration re-clones every repo through
  mast-clone into `C:\MAST\src` -- tokenless by construction -- and deletes
  `C:\MAST\repos` outright, taking the old tokenized config with it. Hand-editing the
  remotes first would be work the migration undoes.
- **Deleting the `.gitignore` rules** now that the token file is gone. Kept
  deliberately as a guard against re-introduction -- the rule costs nothing and the
  failure it prevents is a secret in git history.

**Unsettled:**

- **Expiry alone would not have broken the current path.** GitHub ignores invalid
  credentials on a public repo (verified with `git ls-remote` and a bogus token), so
  the removal is hygiene rather than an outage fix. Worth recording because the
  opposite is the intuitive assumption and would have led to treating expiry as the
  deadline.
- **#17 does not close here.** The exposed string stays in each unit's `.git/config`
  until the stage-6 migration deletes `C:\MAST\repos`, so the fix is landed on the
  build side and pending on the fleet.
- **The reversal path is written down but untested:** if a MAST repo goes private
  again, the answer is an org-scoped `url.<...>.insteadOf` rewrite or a credential
  helper, never a token baked into a remote URL. Nobody has exercised that path.
- **"All seven repos are public" was verified once**, on 2026-08-02. Nothing watches
  for one of them flipping to private.

**Implications:** A dev/test build no longer needs a credential to exercise the `mast`
module, which removes the last reason `-TestMode` differed from a production build on
secret material.
