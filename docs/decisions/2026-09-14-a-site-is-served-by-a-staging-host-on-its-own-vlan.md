---
decided: 2026-09-14
status: accepted
issue: MAST_provisioning#186
areas:
  - transfer
  - networking
  - orchestration
  - storage
---

# A site is served by a staging host on its own VLAN, and the orchestrator need not be there

**Why:** a unit pulls its payload over SMB, so it has to open TCP 445 to whatever serves that payload. At Neot Smadar only a host on the units' own VLAN qualifies. A run driven from the institute therefore stops before it starts: a dry run of mast07 on 2026-09-10 reached `PREFLIGHT_UNIT_SMB_FAIL unit=mast07 address=132.76.233.169 port=445` — SSH routes to the site and SMB does not. The 2026-09-02 measurements say the same thing from the other side: a *routed* staging path ran at 48–50 MB/s at best and collapsed to 0.14–0.25 MB/s four times out of six, with no error of any kind.

Until now "the machine that orchestrates" and "the machine that serves the payload" were the same machine, and `local_address_for()` encoded that: it returns *this* host's address on the route to the unit, which is the right answer only while this host is what the unit pulls from.

**What:** they come apart. A site may declare a **staging host** in `server/data/staging-hosts.json`. When one is declared, the orchestrator still builds locally, then rsyncs the payload to that host and hands the unit *its* address and share. When none is declared — the bench, the dev VM — nothing changes at all.

`server/prov/relay.py` holds the declaration, the UNC and path derivations, and the rsync invocation. `Driver._process_unit` resolves the relay for `unit.site` and sets `prov_address` from it, which carries automatically into `_unit_can_reach_staging` (so the reachability gate probes the host that will actually serve) and into `_transfer`'s `src_unc`, now parameterised by share name. A new phase 5c between classification and the availability lease does the sync and **fails closed**, because executing against a relay copy that is stale or half-written is precisely the failure this phase introduces.

The pull itself is untouched: same `mast-pull-staging.ps1`, same per-module exclusions (#195), same destination verification (#189). Only the address and share name the unit is handed change.

**The economics come from the vendor mirror already being there.** `/Storage/mast-vendor` holds 12,918,167,762 bytes of a 14,877,432,438-byte payload (#194). `tools/build-vendor-view.sh` presents those under the names a *staging root* uses — the store keeps `ps3-catalog/` as a directory, the payload stages its two files at the root — and that view is passed as a `--link-dest`. rsync then hardlinks 87% of a host tree rather than sending it. The view costs about 1 MB of directory blocks for 13 GB of content, and a second host tree measured **199 bytes and 1.4 s**, with matching inodes and no growth in `du`.

**Rejected:**

- **Moving the orchestrator to the site.** The obvious fix and the reason this is the second attempt: labcomp2 is a laptop that has held five addresses in two months. Tying fleet provisioning to where a laptop is sitting is what the declaration removes.
- **Reusing the operational `mast-share`.** It needs no root, the units already mount it, and the credential already exists — but it is **read-write**, so a unit could write into the payload it is about to execute from, and the credential is the operational one. A dedicated read-only share turned out to need no new Samba account either (`valid users = mast`, as `mast-share` already uses), so the objection cost nothing to remove.
- **A mapping table from staging-root entries to vendor-store paths.** The first design. The staging-shaped `vendor-view` replaces it: rsync compares by name, so giving the names the right shape once means no table to keep in step with the build.
- **Falling back to the orchestrator when a site's entry is malformed.** Rejected as the worst possible behaviour: it points the unit at a host it cannot reach *and* looks exactly like a config that has not been picked up. `load_staging_hosts` raises naming the site.
- **Cross-version `--link-dest` chains and `--checksum`.** Planned, then dropped. With #195 the steady-state payload is ~20 MB; chaining optimises a cost that no longer exists, and `--checksum` would buy correctness against mtime churn that the vendor mirror's `-t` already avoids.
- **Deriving the relay address rather than declaring it.** There is nothing to derive it from: the relay is not on the route between the orchestrator and the unit in any way the kernel can report.

**Unsettled:**

- **Nothing yet proves the hardlinking works in the real sync.** The mechanism is proven standalone (199 bytes, matching inodes) and the flags are unit-tested, but the attribute comparison degrading to a full copy is **silent** — it produces no error, just 14.9 GB per host forever. The acceptance is a link-count assertion on the relay after a real run, and it has not been run.
- **No retention on the relay.** `payload/` and `hosts/` grow without bound; nothing prunes a host tree for a unit that is gone.
- **A run now spans two failure domains** — orchestrator at the institute, staging at the site — and the relay is the same machine that serves the fleet's operational storage.
- **The identity path is a default in `relay.py`** (`/cygdrive/c/Users/labcomp2/.ssh/id_ed25519`), which names a specific build host in code.
- **`vendor-view` drifts if the vendor store changes** and nothing rebuilds it automatically; #194's manifest is what would make "has it changed" answerable.
