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

One `.lic` file per licensed unit. The build script (`build/build-mast.ps1`)
allocates them to hostnames and tracks the assignment in
`server/providers/nomachine/assets/licenses/allocated.csv`.
