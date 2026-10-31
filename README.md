# Home Proxy Gateway

Routes every device on a home LAN through a static (non-rotating) proxy exit IP,
using policy-based routing on a MikroTik router and a Linux VM running
[tun2socks](https://github.com/xjasonlyu/tun2socks) as the SOCKS5-to-TUN gateway.

No device needs any per-app proxy configuration — the redirection happens
transparently at the router, for every device on the LAN, including DNS.

## Why this exists

Consumer VPN apps rotate IPs, cap devices, or don't run on routers. This setup
instead gives a whole LAN a single, stable exit IP backed by a paid static
proxy (residential/ISP proxy) service, with:

- A kill switch: if the proxy gateway goes down, affected devices lose
  internet instead of silently falling back to the real ISP IP.
- No DNS leak: DNS queries are routed through the same tunnel as everything
  else, not resolved locally by the router.
- An instant, single-command rollback to normal internet.

## Architecture

```
┌─────────────┐      ┌──────────────────┐      ┌─────────────────────┐      ┌─────────┐      ┌──────────┐
│ LAN device  │─────▶│ MikroTik router   │─────▶│ Linux VM (proxygw)  │─────▶│ SOCKS5  │─────▶│ Internet │
│ (any)       │      │ policy routing    │      │ tun2socks: TUN↔SOCKS│      │ proxy   │      │          │
└─────────────┘      └──────────────────┘      └─────────────────────┘      └─────────┘      └──────────┘
                       runs on RouterOS          runs as a VirtualBox VM
                       (physical hardware)        on the home PC
```

1. A LAN client sends traffic as normal; its default gateway is still the
   router (clients need zero configuration).
2. The router has a policy routing rule that, for LAN source addresses,
   looks up a next-hop of the gateway VM instead of the normal WAN — this
   happens transparently, the client never knows.
3. The VM runs `tun2socks`, which owns a `tun0` interface. Traffic forwarded
   to the VM is NAT'd onto `tun0`, which `tun2socks` relays out over a SOCKS5
   connection to the proxy provider.
4. If the proxy/VM is unreachable, the router's route lookup fails and the
   traffic is dropped (not rerouted to the real WAN) — this is the kill switch.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full breakdown,
including why a MikroTik can't do this with a native proxy client and why a
VM gateway is required.

## Status

Working, in daily use. See [docs/OPERATIONS.md](docs/OPERATIONS.md) for the
two most common questions people ask about a setup like this:

- **"Can I disconnect/shut down the PC?"** → No, read why in Operations.
- **"What happens if the PC restarts?"** → Mostly automatic, with one caveat.
  Read Operations before you rely on it.

## Repo layout

```
docs/
  ARCHITECTURE.md     full design + why native MikroTik proxying isn't possible
  SETUP.md            step-by-step build instructions (VM, service, router)
  OPERATIONS.md        reboot behavior, disconnecting the PC, emergency bypass, failure modes
  TROUBLESHOOTING.md   every real issue hit while building this, and the fix
  DETECTION.md         why a service might flag "VPN/Proxy detected" and what's fixable
configs/
  proxygw.service.template   systemd unit for the tun2socks gateway
  proxygw-net.sh              post-up network/killswitch script run by the service
  mikrotik-setup.rsc.template RouterOS script with the policy routing rules
  decodo.env.example          proxy credentials file format (placeholders only)
local/                        (git-ignored) real credentials/IPs for this
                               specific deployment — never committed
```

## Credentials and IPs

This repo contains **no real credentials, IPs, or identifying network
details** — every config file uses placeholders. The actual working values
for this deployment live in `local/`, which is git-ignored and stays on the
machine that built this. If you're reproducing this setup, fill in your own
values following `configs/decodo.env.example` and
`configs/mikrotik-setup.rsc.template`.

## License

MIT — see [LICENSE](LICENSE).
