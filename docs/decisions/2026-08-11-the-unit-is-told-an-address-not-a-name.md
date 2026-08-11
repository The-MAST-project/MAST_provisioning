---
decided: 2026-08-11
status: accepted
issue: MAST_provisioning#70
areas:
  - transfer
  - networking
  - orchestration
---

# The unit is told an address, not this machine's name

**Why:** no production unit could pull a payload. Every transfer died the same way:

```
TRANSFER_START  unit=mast03  files=403  bytes=14644086299  src_unc=\\AP-PC-PF62XRLL\mast-staging\mast03\01-provisioning
TRANSFER_FAIL   unit=mast03  reason=net_use_failed  rc=2  detail=net.exe : System error 53 has occurred.
```

Error 53 is "network path was not found" — the unit could not resolve `AP-PC-PF62XRLL`. It resolved it through a `hosts` entry pinned to a link-local address:

```
mast01   169.254.215.207  AP-PC-PF62XRLL  # MAST-BENCH-PROV
mast02   (no entry at all)
mast03   169.254.215.207  AP-PC-PF62XRLL  # MAST-BENCH-PROV
mast04   169.254.215.207  AP-PC-PF62XRLL  # MAST-BENCH-PROV
```

`169.254.x.x` is what Windows assigns when DHCP fails, so this was captured during a bench session. The marker `MAST-BENCH-PROV` appears **nowhere in this repository**: the entries were placed by hand, which is why one unit lacks one and why the other three are stale identically. Nothing would ever correct them.

The root cause was one line, and a conflation inside it:

```python
self.prov_server = os.environ.get("COMPUTERNAME") or socket.gethostname()
```

That single value served two unrelated jobs. As the execute lease's `held_by` it is an **identity** — and a name is right there, since it says who holds the run and must survive a DHCP change. In the staging UNC and the pull script's argument it is an **address** — and this machine's own `COMPUTERNAME` is a bad one, because it is only meaningful to the unit if some external mechanism maps it, and no such mechanism was ever built.

So the unit was being asked to resolve a name that exists for the server's benefit.

**What:** the two roles are separate values.

- `prov_identity` — `COMPUTERNAME`. Used for `held_by` and log lines only.
- `prov_address` — set **per unit**, this machine's address on the route to that unit. The UNC and the pull script's new `-ProvAddress` parameter are built from it.

The address is derived by asking the kernel, not by choosing from the interface list:

```python
s = socket.socket(AF_INET, SOCK_DGRAM)
s.connect((unit_ip, DISCARD_PORT))  # UDP connect sends nothing; it binds
return s.getsockname()[0]
```

Choosing from the list is precisely what had to be avoided. This machine has seven IPv4 addresses — one routable, one VirtualBox host-only, five APIPA — and a hand-picked one is how `169.254.215.207` got written into three units. Route-based selection has no heuristic to get wrong, needs no "skip 169.254" rule, and is stdlib-only and identical on Linux and Windows, so it costs the platform-agnostic server nothing.

Two supporting changes:

- `PROV_ADDR` logs the derived address and the unit IP it was derived for. `PROV_ADDR_FALLBACK` logs the case where no route could be derived and the name is used after all — the old behavior, kept as a fallback but never silent.
- A pre-build reachability probe from the **unit** to that address on 445, reported as `PREFLIGHT_UNIT_SMB_FAIL`. The failing run built for ~3 minutes and planned a 403-file, 14.6 GB transfer before discovering error 53. `Test-MastSmbHostReady` could not have caught it: it validates the server's own shares and passed on that very run. The direction that matters is unit → server.

**Rejected:**

- **Give the provisioning server a stable DNS name or static address.** The first recommendation on #70, and it works — `mast-ns-control` and `mast-ns-spec` are already reached by name. Rejected as the primary fix because it *maintains* the dependency rather than removing it: it needs a DNS record kept in step with a machine whose address drifts, and a unit that cannot resolve it fails exactly as before. Deriving the address per run has no state to keep in step. Nothing here prevents also giving the server a DNS name for human use.
- **Have provisioning own a refreshed `hosts` entry**, written by bootstrap or an early provider from the server's current address. Better than by hand, and `bootstrap-winrm.ps1` already writes this shape for `mast-wis-control` in VM test mode. Rejected for the same reason: it is a cache of something derivable, so it can be stale, and it only refreshes on a run that reaches the unit — while a stale entry is exactly what stops a run reaching the unit.
- **"Use the first non-APIPA IP."** The obvious shortcut, and wrong on this machine: it would pick either `10.23.2.34` or the VirtualBox `192.168.56.1` depending on enumeration order, and the host-only address is correct for a dev VM and useless for a production unit. The right address is a property of the route, not of the interface list.
- **Kerberos concerns about an IP-based UNC.** An IP target forces NTLM. Moot here: there is no domain and there is not expected to be one, and the share authenticates with a local `mast-transfer` account, so Kerberos was never in play.
- **Removing the units' `hosts` entries in this change.** They are inert once this lands. Deleting them is an operational step on four production machines, better done supervised; #70 stays open to carry it.

**Unsettled:**

- **The UNC is no longer a per-run constant.** Two units on different subnets legitimately get different addresses from the same run — correct, and the code no longer assumes otherwise, but it is the kind of assumption that gets reintroduced later.
- **`PROV_ADDR_FALLBACK` is untested in the field.** It fires when no route can be derived, which on a working network does not happen; the path is covered by unit tests only.
- **The stale `hosts` entries are still on mast01, mast03 and mast04, and mast02 still has none.** Harmless once nothing resolves that name, and a trap for the next person who assumes they mean something.
- **Whether the pre-build probe belongs on every unit, every run.** It is one extra round trip per unit per cycle to catch a condition that should be rare. Cheap, but it is a cost paid always for a failure that is occasional.
