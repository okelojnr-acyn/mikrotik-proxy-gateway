# Architecture

## The constraint that shapes everything

Most consumer/SOHO routers — including MikroTik's RouterOS on non-ARM/x86
boards — cannot run a SOCKS/HTTP proxy client natively. RouterOS 7 supports
containers only on x86 and some ARM64 boards; MIPS-based routers (e.g. the
hEX S / RB760iGS used here) cannot run containers at all, which rules out
running `tun2socks` or similar directly on the router.

A VPN protocol (WireGuard/OpenVPN) *can* run natively on the router — but
this project's exit point is a **SOCKS5 proxy** (a paid static-IP ISP/residential
proxy service), not a VPN server. RouterOS has no native SOCKS5 WAN client.

The fix: put a small Linux box *on the LAN* whose only job is to speak
SOCKS5 to the proxy provider and expose a plain IP interface (`tun0`) that
the router can treat as a normal next-hop gateway. The router then uses
**policy-based routing** to send LAN traffic to that box instead of its own
WAN interface. No VPN or container support is required anywhere.

## Components

### 1. MikroTik router — policy routing, not a VPN endpoint

The router's job is just to decide, per source address, which routing table
to use:

- `main` table — normal route out the real WAN. Used for:
  - the gateway VM's own traffic (so *it* can reach the proxy provider
    directly, not loop through itself)
  - LAN-to-LAN traffic (so devices can still reach each other / the router)
- `via-proxy` table — a table containing a single default route whose
  gateway is the VM's LAN IP. Used for everything else on the LAN.

A `/routing rule` with `action=lookup-only-in-table` is what makes this a
kill switch: if `via-proxy`'s route is down (gateway unreachable), there is
no `main`-table fallback for matched traffic — it's just dropped.

### 2. Gateway VM — tun2socks

A small Linux VM (Ubuntu Server, headless, 2 vCPU / 2GB RAM is plenty) runs
[`tun2socks`](https://github.com/xjasonlyu/tun2socks), which:

- creates a `tun0` virtual interface
- relays everything routed onto `tun0` over a SOCKS5 connection to the
  proxy provider (`-p socks5://user:pass@host:port`)
- exposes `--tun-post-up` to run a script once `tun0` exists, which is
  where the NAT/forwarding/kill-switch rules are set up

The VM is reachable from the router as `<vm-lan-ip>` and the router's
`via-proxy` default route points at it directly — it behaves like any LAN
gateway box, just one hop deeper.

### 3. The VM's own kill switch (defense in depth)

Independent of the router's kill switch, the VM itself refuses to leak:
traffic *forwarded into it* (i.e. arriving on its LAN NIC from other
devices) is only allowed out via `tun0`; if `tun0`/the proxy is down, that
forwarded traffic hits an explicit `blackhole` route rather than falling
back to the VM's own direct internet path. The VM's *own* traffic (e.g.
`apt update`) is unaffected — only traffic being relayed for other LAN
devices is restricted this way.

```
ip rule add iif <lan-if> lookup 100       # table 100: default route via tun0
ip rule add iif <lan-if> blackhole        # if table 100 has no route, drop
```

### 4. Why FastTrack breaks this (RouterOS-specific)

RouterOS's FastTrack firewall rule accelerates established connections by
bypassing the firewall *and the routing-rule evaluation* for subsequent
packets of a flow. In practice this means: any connection that was already
established **before** a policy routing rule was added keeps using its old
route forever, invisibly, regardless of new rules. This is a real, easy way
to leak traffic if you add policy routing to a router that already has
FastTrack enabled and active connections.

**Fix:** disable FastTrack (`/ip firewall filter disable
[find action=fasttrack-connection]`) and flush `/ip firewall connection`
for the affected subnet whenever routing rules change. On a home network the
CPU cost of disabling FastTrack is negligible — the real bottleneck is the
proxy provider's own bandwidth cap, which is far below what a MikroTik can
push with normal (non-accelerated) forwarding.

### 5. Why DNS needs separate attention

Many router configs transparently redirect all port-53 traffic to the
router itself (`dst-nat` to the router's own resolver) regardless of what
DNS server a client is configured to use — often for content filtering or
ad blocking. If that redirect exists, DNS queries are resolved **by the
router**, using the router's own route (real WAN) — not the client's
route — even after policy routing sends the client's other traffic through
the proxy. This is a DNS leak: browsing traffic looks like it's coming from
the proxy's country, but DNS resolver metadata (and anything using
EDNS Client Subnet) reveals the real location.

**Fix:** disable the DNS dst-nat redirect for the affected LAN segment only.
Once disabled, DNS queries become ordinary UDP/TCP port-53 traffic from the
client, which gets policy-routed through the proxy like everything else.

**How to verify DNS isn't leaking:** query Google's resolver debug record,
which echoes back the EDNS Client Subnet it saw attached to your query:

```
nslookup -type=TXT o-o.myaddr.l.google.com. 8.8.8.8
```

The `edns0-client-subnet` value in the response should match the proxy
provider's IP range, not your real IP range.

## Example addressing used in this repo's docs

| Thing | Example value |
|---|---|
| LAN subnet | `172.16.50.0/24` |
| Router LAN IP | `172.16.50.1` |
| Gateway VM LAN IP | `172.16.50.237` (static DHCP lease) |
| Gateway VM LAN interface | `enp0s3` |
| `via-proxy` routing table | holds one route: `0.0.0.0/0` via the VM IP |

Substitute your own addressing — none of this needs to match exactly, the
pattern is what matters.

## Known limitations

- IP-level geolocation changes, but TLS fingerprint, timezone, browser
  language, and WebRTC can still reveal more than the exit IP does. This
  setup only changes the network-layer exit point.
- Throughput is capped by the proxy provider's plan, not by this setup
  (see Troubleshooting for the TCP tuning that got close to the provider's
  real ceiling).
- The gateway VM runs *on the same PC* as everyday use — see
  [OPERATIONS.md](OPERATIONS.md) for what that means for uptime.
