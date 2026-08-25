# vault/

This directory holds secrets and per-deployment configuration. **It is gitignored**
(`vault/` is in `.gitignore`); never commit anything here.

## Required contents

```
vault/
├── README.md                 # this file (only thing checked in)
├── creds.json                # WinRM credentials for unit VMs/machines
└── nomachine-licenses/
    └── *.lic                 # one .lic file per licensed unit
```

## creds.json

Single-machine bring-up uses one `unit` block:

```json
{
    "unit": { "user": ".\\mast", "pass": "<unit-mast-password>" }
}
```

The autonomous driver additionally needs two SMB accounts, which are **not** the same
thing:

- `smb` -- the read-only transfer account on the **provisioning server**, used by
  `client/mast-pull-staging.ps1` to pull the staging payload.
- `shared` -- the account the **operational share** accepts (Samba `valid users` on
  `<controller_host>:/Storage/mast-share`). The driver plants it on the unit as a
  machine-bound DPAPI-LocalMachine blob and the `mast-shared-mount` provider uses it
  to map `Z:` in the SYSTEM session. Without it the unit silently writes exposures to
  `C:\MAST` -- see issue #25.

Use `creds.json.template` as a starting point.

## tokens/ -- removed 2026-08-02

There is no GitHub token any more. Every The-MAST-project repo is public, so the
`mast` provisioning module clones anonymously over HTTPS. The old PAT was
embedded in each clone's remote URL, leaving a live secret in `.git/config` on
every provisioned unit (issue #17); deleting it removes the secret rather than
managing it better. If a repo ever goes private again, add an org-scoped
`url.<...>.insteadOf` rewrite -- never a token in a remote URL. The `.gitignore`
rule for `tokens/` is deliberately left in place to guard against
re-introduction.

## nomachine-licenses/

**This is the only place NoMachine certificates live.** One `.lic` file per
licensed seat. `build/build-mast.ps1` reads the seat-to-host assignment from
`server/providers/nomachine/assets/licenses/allocated.csv` and the certificate
itself from **here**, then stages it as the payload's `nomachine.lic`.

Do not keep a second copy next to `allocated.csv`: the build fails if it finds
one, because an unread copy drifts silently from what ships. That is how
expired certificates reached mast06 and mast07 on 2026-08-23 -- see that
directory's `README.txt` for how to fetch and check a set.
