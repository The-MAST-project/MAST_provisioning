# Areas in use

The working list of `areas:` terms across the decision records. It is **descriptive, not
prescriptive**: it records the terms actually in use so they can be reused, and it changes
as the system does.

**Consult it, don't obey it.** Reuse a term when one fits -- that is the whole value, since
scattered synonyms make the field unqueryable. But if nothing here describes your decision,
**coin a term and add it below in the same PR**. A decision worth recording is often exactly
the one that fits no existing bucket; the list follows the records, never the reverse. Terms
here have no authority beyond "someone found this useful before."

## Current terms

Seeded 2026-08-07 from the subject matter of the 118 archived entries, so the list starts
from what this repo has actually decided about rather than from a taxonomy invented up
front. Expect it to be wrong in places and to shift.

| Area | Roughly |
|------|---------|
| `bootstrap` | First-touch unit prep: the `mast` account, autologon, rename, remoting enablement |
| `transport` | How the server reaches a unit -- WinRM, SSH, timeouts, retries |
| `transfer` | Moving the payload onto a unit, and the shares and ACLs that carry it |
| `credentials` | The vault, DPAPI blobs, tokens, which identity is used for what |
| `proxy` | bcproxy posture, WPAD, cert revocation, per-run network mode |
| `networking` | NIC drivers, addressing, firewall posture, cross-subnet reachability |
| `timesync` | Clock sources, NTP, timezone handling |
| `storage` | Drive letters, mounted shares, RAM and sparse disks |
| `providers` | The provider model: discovery, ordering, `module.json`, manifests |
| `drift` | Installed-vs-expected: per-module state, hashes, fleet reports |
| `orchestration` | The server control plane: the driver, loop/service mode, detached execute |
| `scheduling` | Maintenance windows, leases, TTLs, heartbeats |
| `logging` | Log paths, archival, retention, noise control |
| `services` | The NSSM MAST services: naming, start policy, dependencies |
| `unit-config` | Per-unit and per-site configuration, and the unit registry |
| `instruments` | Mount, focuser, cameras, instrument profiles, COM binding, calibration |
| `astrometry` | Plate solving, index files, the cygwin toolchain |
| `source-layout` | Where unit code lives: clone tooling, repo set, venv, remotes |
| `dev-harness` | The VM test loop: snapshots, scenarios, `run-prov-test` |
| `docs-process` | How this repo records and communicates its own decisions |
| `rationale retrieval` | Getting from a piece of code to the reasoning behind it |
| `PR conventions` | What a pull request is expected to carry |
| `failure reporting` | Whether the system's own report matches what happened -- fail-closed vs fail-open, a silent success, a warning where a failure belongs |
| `platform independence` | Running the same way from a Linux or a Windows server, with no per-platform branch |
| `reproducibility` | A build or install producing the same result twice: pins, frozen caches, vendored artifacts |
| `service logon sessions` | Which logon session a thing exists in -- LocalSystem vs interactive -- and what is visible from where |
| `drive letters` | Windows drive letters as a naming mechanism, and what they can and cannot carry |
| `the operational share` | The site controller's science share, and the contract units have with it |
| `operator tooling` | What a person standing at a unit uses, with no controller and no network |
| `fleet migration` | One-time, supervised changes applied across production units |
| `hardware startup` | When a device is powered, homed or moved, relative to when software starts -- process lifetime versus hardware lifetime, and who commands the transition |
| `static analysis` | What is checked without running the code: lint, formatting, type checking, the PowerShell parse sweep -- rule selection, what is deferred, and whether the gate blocks |

Added 2026-08-17 with the pyright record. Distinct from `reproducibility`, which covers the
*pins* that make a checker's verdict stable, and from `docs-process`, which the earlier CI
record reached for because nothing better existed. The recurring subject is the gating
itself -- the ruff adoption, its deferred families (#72), PSScriptAnalyzer (#73) and now the
type checker are four decisions about the same thing.

Added 2026-08-16 with the supervision record, which is the first decision to turn on the
distinction. It is not `instruments`: that term covers the devices themselves -- binding,
profiles, calibration -- where this one covers *when* they act. A process start that opens
the mirror covers is a `hardware startup` decision; the mount's COM binding is an
`instruments` one.

Added 2026-08-09 with the 27 rewritten v3-branch records. Four of them
(`platform independence`, `service logon sessions`, `the operational share`, `drive
letters`) were already used as examples in this file and in `README.md` without being
listed; the inventory made that visible.

Multi-word phrases are fine and often better than forcing a single word (`the operational
share`, `service logon sessions`, `platform independence`). Mixing grains inside one record
is normal -- a decision can be about `storage` and `service logon sessions` at once.

## Retired and merged

When two terms turn out to mean the same thing, pick one, move the other here, and update the
`areas:` of the affected records (permitted -- see *Immutability* in `README.md`: the freeze
protects the prose, not the navigation metadata). A reader who greps the old term then finds
where it went instead of a dead end.

| Was | Now | When | Why |
|-----|-----|------|-----|
| `how this repo records decisions` | `docs-process` | 2026-08-07 | Same subject, and the seeded term was already there -- caught by the first inventory run, on the first record |
| `session isolation` | `service logon sessions` | 2026-08-16 | Same subject under a shorter name: session 0 versus the interactive session, and what each can see. Coined on the supervision record without checking the list, which is the failure mode this file exists to catch |

## Keeping this list honest

The list must follow real usage, so **derive the inventory before curating it** rather than
editing this file from memory:

```bash
awk '/^areas:/{f=1;next} f&&/^  - /{sub(/^  - /,"");print;next} f{f=0}' \
    docs/decisions/2*.md | sort | uniq -c | sort -rn
```

Compare that against the table above and reconcile: add terms in use but missing here, merge
near-synonyms, and retire terms no record uses any more. Worth doing when a record coins
something, and otherwise whenever the output and the table have visibly diverged.

**`areas:` must be a YAML block list** -- one `  - term` per line, never the inline
`areas: [a, b]` form. The inline form is invisible to the command above, so its terms drop
silently out of the inventory and the list rots without anyone noticing.
