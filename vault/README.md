# vault/

This directory holds secrets and per-deployment configuration. **It is gitignored**
(`vault/` is in `.gitignore`); never commit anything here.

## Required contents

```
vault/
├── README.md                 # this file (only thing checked in)
├── creds.json                # WinRM credentials for unit VMs/machines
├── tokens/
│   └── mast_github.txt       # GitHub PAT (repo read scope)
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

## tokens/mast_github.txt

A GitHub Personal Access Token with `repo` scope (read-only is sufficient).
Used by the `mast` provisioning module to clone private MAST repos onto units.

## nomachine-licenses/

One `.lic` file per licensed unit. The build script (`build/build-mast.ps1`)
allocates them to hostnames and tracks the assignment in
`server/providers/nomachine/assets/licenses/allocated.csv`.
