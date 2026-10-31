# Use cases and variations

The core recipe here is: **policy-based routing on the router, to a
gateway that speaks whatever your exit protocol is, with a fail-closed
kill switch.** None of the specific products used while building this
(MikroTik, VirtualBox, Decodo) are load-bearing — they're one concrete
instance of the pattern. This doc covers the variations most worth
knowing about if you're adapting it.

## 1. Whole-home LAN (the documented default)

Every device on one subnet gets the proxy treatment transparently. This
is what [SETUP.md](SETUP.md) and the rest of the docs assume throughout.

## 2. Single device, or a gradual rollout

Don't want to commit the whole LAN at once (or ever)? Scope the routing
rule to one device's IP instead of the whole subnet:

```
/routing rule add src-address=<device-ip>/32 action=lookup-only-in-table table=via-proxy comment=TEST-device
```

See [OPERATIONS.md](OPERATIONS.md) → "Rolling out gradually" for the full
test sequence (verify the exit IP, then the kill switch, before trusting
it). This is also the right approach if you only ever want *one* device
(e.g. a single test phone, or a single smart-TV box) on the proxy and
everything else on normal internet permanently — just never replace the
scoped rule with the whole-subnet one.

## 3. A subnet/VLAN, not the whole LAN (e.g. guest network only)

If your router separates a guest network or IoT VLAN onto its own subnet
already, point the routing rule's `src-address` at that subnet instead of
your main one. Everything else (the VM, the kill switch, the DNS fix)
works identically — the router doesn't care which subnet it's protecting,
only that the subnet's traffic matches the rule.

## 4. A stable outbound IP for development/CI/webhook allowlisting

Some APIs allowlist callers by IP. If your home/office IP changes (most
residential ISPs hand out dynamic IPs) or you don't want to expose it at
all, routing your dev machine's traffic through this same pattern gives
you a **stable** IP to register with that API — same mechanism as the
whole-home case, scoped to one machine (see use case 2).

## 5. Running the gateway without a local VM at all

The gateway VM in this repo's main build exists specifically because the
proxy is **SOCKS5**, which RouterOS can't speak natively. If your exit is
a **WireGuard** peer instead of a SOCKS5 proxy, you don't need a VM, or
even a PC, running at all — RouterOS (on capable hardware) has a native
WireGuard client. The pattern becomes:

```
LAN device → MikroTik (policy routing) → WireGuard peer (a VPS you
control, or a WireGuard-based proxy/VPN provider) → internet
```

with the same `check-gateway` + `lookup-only-in-table` kill-switch rule
pointed at the WireGuard interface instead of a VM's LAN IP. This removes
this project's single biggest structural weakness — the gateway no longer
depends on a daily-use PC staying powered on, connected, and booted
cleanly (see Operations → "Can I disconnect the PC?"). The tradeoff: you
need a WireGuard-speaking exit (run your own `tun2socks`-equivalent or
plain WireGuard server on a cheap VPS, or use a provider that offers
WireGuard config directly) instead of just buying SOCKS5 credentials.

## 6. A different router

The policy-routing + kill-switch pattern isn't MikroTik-specific:

- **pfSense/OPNsense**: "Gateway Groups" plus firewall rules that select
  a gateway per source, with the gateway's own down-detection (dpinger)
  providing the same fail-closed behavior as RouterOS's
  `check-gateway=ping`.
- **OpenWrt** (or any Linux-based router): `ip rule` + a second routing
  table is literally the same mechanism this repo uses on the *VM* side
  (see `configs/proxygw-net.sh`) — just applied on the router itself
  instead of a separate box, if your router hardware is capable enough to
  run the SOCKS5 client directly and skip the VM entirely.
- **Any router with policy-based routing support** works in principle;
  what to check for is (a) per-source routing-table selection and (b) a
  way to make a route's availability depend on a live reachability check,
  not just a static next-hop — that second part is what makes it a kill
  switch instead of just load-balancing.

## 7. A different tunnel/proxy type

`tun2socks` specifically bridges a TUN device to a **SOCKS5** proxy. If
your proxy is HTTP/HTTPS-only (no SOCKS5), you'd swap in a different local
relay capable of transparent redirection to an HTTP proxy (e.g.
`redsocks` with its HTTP-relay mode, or a local `privoxy` chained to the
upstream HTTP proxy) in place of `tun2socks` in the systemd service — the
router and kill-switch side of this repo don't change at all, since they
only ever talk to "the gateway's LAN IP," never to the proxy directly.

## Contributing an adaptation back

If you build one of these variations (or something not listed here),
[CONTRIBUTING.md](../CONTRIBUTING.md) covers how this repo is organized
so an addition fits the existing structure — generic/placeholder docs in
`docs/`, reusable templates in `configs/`, nothing deployment-specific
committed anywhere.
