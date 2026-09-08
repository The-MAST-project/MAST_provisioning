---
decided: 2026-09-08
status: accepted
issue: MAST_provisioning#192
areas:
  - proxy
  - networking
  - failure reporting
---

# The no_proxy default covers the MAST subnets, from one constant

**Why:** the `proxy` provider bypassed `10.23.3.0/24,10.23.4.0/24` while the units live on `10.23.1.0/24` and their PDUs on `10.23.2.0/24`. Neither of the subnets a unit actually talks to was in the list, so every unit relayed traffic to its own network — and to itself — out to `bcproxy.weizmann.ac.il:8080` and back. Measured on mast01 2026-09-03: `http://10.23.1.25:3000/` (Grafana) **times out** through the proxy and answers in full when it is bypassed, while port 80 on that same host relays fine, so this is the proxy declining to relay 3000 rather than a routing or firewall problem. A unit-side link to any dashboard was dead. `http://10.23.1.101:8000/docs` — a unit calling its own FastAPI by IP — also went out to the proxy and came back, which worked and so was never noticed.

**What was decided:**

- The default is **`localhost,127.0.0.1,10.23.0.0/16,169.254.0.0/16`**. The `/16` rather than four `/24`s: it covers the units and the PDUs as well as the two subnets already listed, and needs no edit when MAST takes another subnet. `Convert-NoProxyToWildcardBypass` already handles both CIDR forms, so nothing in the library changed to emit `10.23.*`.
- **Link-local is in the list too.** A `169.254.x` address is by definition not routable, so relaying one to an off-site proxy can never be correct, and it is exactly how a bench unit and the provisioning server address each other (labcomp2's hosts file pins mast06/07/08 there for #132). Independent corroboration for the whole shape: labcomp2's own machine `no_proxy`, hand-set by someone at some point, reads `10.23.0.0/16,192.168.56.0/24,169.254.0.0/16,localhost,127.0.0.1`. The VirtualBox host-only range in it belongs to a provisioning server, not to a unit, and is deliberately not adopted here.
- **The value lives in exactly one place**, `Get-MastDefaultNoProxy` in `proxy-lib.ps1`. It was hard-coded in three: the provider, the shared `Set-MastProxyState`, and the `set-proxy.ps1` desktop tool. Three copies are how a unit provisioned by one path and re-toggled by the other stop agreeing. A `param()` default cannot reach the lib — binding runs before the dot-source — so the two scripts declare the parameter without a default and fill it in immediately after loading the lib, keyed on `$PSBoundParameters`, which leaves an explicit `-NoProxy ''` meaning what it says.
- The value was not invented here. `tools/mast-clone.ps1` has set `localhost,127.0.0.1,10.23.0.0/16` for its own runs all along, so the provider now agrees with the clone tool rather than the reverse; mast-clone gains the link-local range in the same change, since it runs on units too and two tools writing two bypass lists on one machine is the drift this record is about. A test pins the two together rather than trusting them to stay in step.
- **`verify-proxy.ps1` now asserts the bypass list.** It read `no_proxy` and `ProxyOverride` into its log and checked neither — only `http_proxy`, `https_proxy`, `ProxyEnable` and `ProxyServer` — which is why a wrong list was green on the whole fleet for as long as it existed. Both surfaces are now compared against the same default the provider writes, and both are asserted empty in `direct` mode.

**Implications:**

- The provider is `order: 100, always: true`, so the fix reaches every unit on its next run with no targeted repair. A unit not due for one can be corrected in place from the `Weizmann Proxy` desktop shortcut, which shares the lib and therefore the new default.
- **The PDU by FQDN is deliberately not fixed here.** `http://mastps01.weizmann.ac.il/` returns 404 from the proxy and still will: WinINet and WinHTTP match a bypass entry against the host string in the URL, never a resolved address, so a CIDR cannot cover a name. `<local>` already covers the dotless `mastps01`. The real cause is addressing — `mastps01` has no DNS record because the address it should hold is squatted, and `mastps02`'s record points at the wrong IP; both units reach their DLI through a workaround. A blanket `*.weizmann.ac.il` bypass would be worse than the problem, since from Neot Smadar the campus is plausibly reachable only *through* bcproxy.
- Verify still compares against the lib default rather than a value injected from `module.json`. Nothing passes `-NoProxy` today. The moment something does, it has to be plumbed into the verify command the way `desktop-shortcuts` plumbs `-FastApiUrl`, or the assertion checks the wrong thing; the code says so at the point it would break.

**Unsettled:** a verify that *fetches* something on the local subnet rather than comparing a written value. It is the only check that would catch a bypass list which is internally consistent and still wrong, and it is what would have caught this. It needs a reachable Grafana from wherever verify runs, so it is left for its own issue.
