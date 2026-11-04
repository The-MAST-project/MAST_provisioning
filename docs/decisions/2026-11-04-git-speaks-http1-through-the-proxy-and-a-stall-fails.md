---
decided: 2026-11-04
status: accepted
issue: MAST_provisioning#220
areas:
  - proxy
  - source-layout
  - providers
---

# git speaks HTTP/1.1 through the proxy, and a stalled transfer fails

**Why:** Through `bcproxy.weizmann.ac.il:8080`, `git fetch` at git's default HTTP/2 hangs indefinitely once the tunnel is up: four git processes at 0 % CPU for twelve minutes on mast01 (2026-09-22). `git config --global http.version HTTP/1.1`, set by hand on mast01 only, made it work, leaving an occasional `Empty reply from server` that a retry clears.

The 2026-08-31 record *a failed fetch is recorded by the tool and asserted by the provider* makes a fetch that **fails** fail the run. A fetch that **hangs** never reaches that check, because the call never returns. On a unit that means a provisioning run that sits until the 3600 s execute timeout, or a checkout that silently stops moving. The hand edit on one unit is also exactly the out-of-band state this repo exists to remove.

**What:** the same three settings in two places, pinned together by a test.

- **`mast-clone` (both halves)** sets `http.version=HTTP/1.1`, `http.lowSpeedLimit=1000` and `http.lowSpeedTime=60` for its own process, through `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n`.
  - These are appended after any entries the caller already exported.
  - They are environment, not `git config`, for the reason the proxy variables already are: nothing is left behind in a repo or user config. That matters for the script's other consumers, developers' machines and MAST-control.
  - Every machine that runs it has git 2.31 or later, which the mechanism needs. Measured 2026-11-04: units 2.52, MAST-control 2.43, the Mac 2.54.
- **The low-speed pair turns a stall into an error.** A transfer under 1000 B/s for 60 s is aborted, and `fetch_ok` records it.
- **Clone and fetch are retried:** up to 3 attempts with a 5 s pause, `Invoke-GitNetwork` in the `.ps1` and `run_net` in the `.sh`. That absorbs the residual `Empty reply`.
  - **Once one call has used up its attempts, the rest get one each.** A proxy that is down is down for every repo. 8 network calls × 3 attempts × 60 s would spend most of a unit's execute budget on it.
  - **A clone that leaves its folder behind is not retried.** git removes the folder after a transport failure, but keeps it when the checkout fails (a path Windows refuses, say). No retry fixes that, and a retry would bury the cause under `destination path already exists`.
- **A new provider, `git-http`** (order 710, after `git`, `always: true`), writes the same values with `git config --system` and reads them back. A shared `mast-git-http-lib.ps1` holds the one table.
  - This covers what `mast-clone` cannot reach: an operator's fetch in VS Code or a shell under `mast`, a service's process, and `verify-mast.ps1`'s own `git ls-remote`, which would otherwise hang a run the same way.
  - It is `always` because a value changed out of band produces no payload-hash drift, which is the long-paths record's reasoning.

**Evidence** (2026-11-04, labcomp2, Windows PowerShell 5.1, git 2.54):

- **A real clone through a local proxy** that chains to bcproxy and stops relaying after 64 KB, with the tunnel up and data already flowed, which is #220's shape:
  - with the low-speed pair, git exited after 67 s with `curl 28 Operation too slow. Less than 1000 bytes/sec transferred the last 60 seconds`;
  - without it, git was still hanging at 150 s, when it was killed.
- **Both halves of `mast-clone`** against a fake git that fails every fetch: 5 fetch calls for three repos (3 + 1 + 1), all three `fetch_ok: false`, and the settings appended after a caller-supplied entry.
- **The provider** against a throwaway `GIT_CONFIG_SYSTEM`: verify fails an empty or tampered config, provide repairs it, and verify passes. The comparison is case-sensitive, because git matches `http.version` with `strcmp`: `http/1.1` is an unknown value it ignores, falling back to HTTP/2.
- **CI** runs `mast-clone.sh` against a fake git on the Linux runner (`test_git_http_provider.py`). It pins the 3 + 1 + 1 budget, the append after a caller's entry, and the clone that is not retried.

**Rejected:**

- **Only the `--system` setting, as the issue's ask 1 put it.** It covers everything git runs on a unit, but not `mast-clone` on a developer's machine or MAST-control, nor a unit whose `git-http` module has not run yet. A first provisioning installs git at order 700 and clones at 2200, so it would be covered, but `mast-clone` is also run by hand.
- **Making the `git` provider itself `always` and adding the write there.** That would re-run an installer module every run to maintain three config values, and its `provide-git.ps1` exits early when Git is present. A separate module keeps the installer's drift meaning what it meant.
- **A fetch timeout in place of the low-speed pair.** A wall-clock bound has to be generous enough for a first clone of the largest repo, which makes it useless against a hang. The low-speed pair measures progress instead.
- **A black-hole proxy address as the manual test.** It fails at TCP connect, which the connect timeout governs, so it would pass even with the low-speed pair missing.

**Unsettled:**

- **mast01 keeps a hand-set `git config --global http.version HTTP/1.1`** for the `mast` account, from 2026-09-22. `--global` outranks `--system`, and `verify-git-http` reads only `--system`, so provisioning does not own the setting for that account. The value is identical today, so it does no harm. But if the provider's value ever changes (dropping HTTP/1.1 once bcproxy handles HTTP/2), that account keeps the old one silently. It is a one-time removal on mast01, recorded on #220, not something a provider should go looking for in user profiles.
- **#220's third ask is not answered:** whether other HTTP/2 clients through bcproxy hang the same way. uv's downloads and `uv pip install` go through the same proxy, and nothing here bounds them.
- **The low-speed pair covers a stall after the tunnel is up,** which is the shape #220 recorded. A proxy that accepts the connection and never answers the CONNECT is governed by curl's connect timeout instead (300 s by default), which git does not let a config key set. Bounded, but slow.
- **The `.ps1` retry behavior has no CI runner.** It was checked on labcomp2 (above). The Windows CI job could run the same fake-git scenario under PowerShell 5.1; it does not yet.

**Implications:**

- **#220's loopback half,** where curl on a unit sends `localhost` to the proxy, is a different consumer and stays open. It belongs with MAST_provisioning#192, the proxy bypass list that omits the units' own subnets.
- **The first run of this change touches every unit's `mast` and `git-http` modules.** `mast-clone.ps1` is a `repofiles` entry of `mast`, so its hash moves.
