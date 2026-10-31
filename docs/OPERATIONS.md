# Operations

## Can I disconnect the PC from the router?

**No — not if you want the LAN to keep having internet.**

The gateway is a VM running *on* the home PC, bridged to that PC's physical
Ethernet adapter. That means three things are all simultaneously true:

1. The PC must stay **powered on**.
2. The PC must stay **connected to the router by Ethernet** (bridged
   networking needs a live physical link; Wi-Fi bridging is not used/not
   reliable for this).
3. VirtualBox must be running with the gateway VM up inside it.

If any of those three breaks, the gateway VM becomes unreachable from the
router. Because the whole LAN's routing rule has no fallback (that's the
point — it's the kill switch), **the entire LAN loses internet** until the
PC/VM/cable situation is fixed. It fails *closed*, not open — nothing leaks
to your real IP, but nothing works either until the gateway is back.

If you want the proxy running independently of this PC, the fix is to move
the gateway VM onto something that's always on — a small dedicated PC, a
NUC, a Raspberry Pi (if performance allows), or a cheap VPS if you don't
need the exit IP to be on your home network's hardware. That's a future
improvement, not something this setup currently does.

## What happens if the PC restarts?

Partially automatic, with one real caveat:

1. Windows boots.
2. **A scheduled task (`StartProxyGW`) fires at user logon** and starts the
   VM headless. This means: nobody needs to open VirtualBox manually — but
   it also means **the VM will not start until someone actually logs into
   Windows**. A restart that sits at the lock screen does not start the VM.
3. Inside the VM, the `proxygw` systemd service is enabled, so once the VM
   boots, the gateway starts itself and reapplies routing/kill-switch rules
   automatically — no manual steps needed inside the VM.
4. **Known flakiness:** roughly half of cold boots of this particular VM
   hang partway through kernel driver init (`Loading essential drivers...`)
   for reasons that look like host CPU scheduling jitter rather than
   anything in the VM's own config — see Troubleshooting. If this happens,
   the VM sits there unreachable indefinitely; it needs a manual power-off
   + start to recover. There's no automatic recovery from this today.
5. The MikroTik's own configuration (routing tables, rules, FastTrack
   disabled, DNS redirect disabled) lives on the router itself and survives
   PC/VM restarts independently — you never need to redo router config just
   because the PC rebooted.

**Practical takeaway:** after any PC restart, check that LAN devices have
internet. If they don't, log into Windows (if not already), open
VirtualBox, and check the `proxygw` VM — if it's stuck at a boot log screen
rather than a login prompt, power it off and start it again.

## Failure modes — what actually happens when something breaks

The router's kill-switch route has a `check-gateway=ping` pointed at the
**gateway VM's LAN IP** — a purely local check. It tells you whether the VM
is reachable on the LAN. It tells you *nothing* about whether the VM can
actually reach the proxy provider over the internet. That one fact explains
why different failures look and feel different, even though none of them
leak:

### The VM/router path itself fails (VM crashed, hung, or unreachable)

The router's gateway check fails, the `via-proxy` route goes down, and
because the LAN's routing rule has no fallback table, affected traffic is
dropped outright. This is the kill switch working as designed: **fails
closed, cleanly, immediately.** Nothing leaks to the real IP; nothing works
either, until the VM is reachable again.

- If it's just the `tun2socks` process that died (not the whole VM),
  `systemd` (`Restart=always`, `RestartSec=3`) brings it back in a few
  seconds on its own — the VM's own kill-switch rule (a `blackhole` route)
  protects forwarded LAN traffic during that brief gap.
- If the whole VM is hung or crashed (including the known intermittent
  boot-hang — see Troubleshooting), the in-VM healthcheck can't help,
  since its own watchdog dies with the VM. A **host-side watchdog**
  (`configs/vm-watchdog.ps1.template`, scheduled every minute) closes this
  gap: it checks the VM's state and LAN reachability from the Windows
  host, and power-cycles it after a few consecutive failures (deliberately
  debounced so one dropped ping doesn't trigger a disruptive power-cycle).
  See Setup → "Host-side VM watchdog" for installing it.
- A VM that's "running" per VirtualBox but unreachable from the LAN after a
  host NIC link event (cable unplug/replug) is a distinct, previously-seen
  issue — see Troubleshooting for the fix (full VM power-cycle, not just a
  NIC link toggle).

### A brief ISP/WAN glitch (seconds to a minute or two, not a real outage)

This is the subtle one. The VM stays fully reachable *on the LAN* the whole
time, so the router's gateway check never trips and the route **never goes
down**. The router keeps forwarding LAN traffic to the VM exactly as
before. But the VM's own path out to the proxy provider goes over that same
dead WAN link, so the tunnel can't move data either.

**Net effect: traffic stalls and times out, rather than being cleanly
blocked.** No leak — but it doesn't look or feel like the kill switch
engaging. From a LAN device's perspective this is indistinguishable from a
proxy-provider-side hiccup (see below); the difference only shows up by
checking the router's own WAN interface log for link flaps around the same
time.

A short flap (well under the healthcheck's poll interval) can also leave
**no log trail at all** — the in-VM healthcheck samples periodically with a
short timeout, so it's entirely possible for a sub-minute glitch to resolve
itself in between two checks, or within one check's timeout window, without
ever being recorded. Absence of a healthcheck log entry is not proof that
nothing happened.

### The proxy provider has a hiccup on their end

Looks identical to an ISP/WAN glitch from the LAN's perspective — a stall,
not a leak — since the VM's tunnel depends on reaching the provider over
the internet either way. There's no automatic fallback to a different
proxy/IP on the account; switching exit IPs is a manual edit (see "Changing
the proxy provider or exit location" below).

### The router itself fails or reboots

Routing rules, the `via-proxy` route, and the firewall changes (FastTrack
disabled, DNS redirect disabled) are all saved configuration, not
runtime-only state — they survive a router reboot without needing to be
reapplied manually. The LAN is down for the duration of the reboot itself,
same as any router restart, proxy setup or not.

### General diagnostic note

When something broke and it's not obvious which of the above it was: check
the router's WAN interface log for link-down/up events, and the VM's
`proxygw-healthcheck` journal, for timestamps around the same window — but
make sure both clocks are actually in the same timezone before comparing,
or you'll draw the wrong conclusion about what caused what.

## Emergency bypass — restore normal internet instantly

If the proxy chain is broken and you need internet back immediately, SSH or
Winbox into the router and disable the whole-LAN routing rule:

```
/routing rule disable [find comment=ALL-LAN-via-proxy]
```

This instantly reverts every device on the LAN to normal direct-WAN
routing. Re-enable it later with:

```
/routing rule enable [find comment=ALL-LAN-via-proxy]
```

## Rolling out gradually (test one device first)

Before pointing the whole LAN at the gateway, test with a single device by
scoping a rule to just its IP:

```
/routing rule add src-address=<device-ip>/32 action=lookup-only-in-table table=via-proxy comment=TEST-device
```

Verify (from that device) that an IP-check service shows the proxy's
location, then confirm the kill switch by stopping the gateway service on
the VM and checking the device loses internet (not leaks). Only then
replace the test rule with the whole-subnet rule. See
[SETUP.md](SETUP.md) for the full rollout sequence.

**Important:** flush `/ip firewall connection` for the affected address(es)
after adding or changing routing rules — RouterOS's FastTrack otherwise
keeps pre-existing connections on their old route indefinitely (see
Architecture → "Why FastTrack breaks this").

## Speed tuning

Default `tun2socks` settings left real throughput well below what the proxy
plan allowed. Enabling TCP auto-tuning and larger buffers roughly doubled
measured throughput in testing:

```
--tcp-auto-tuning --tcp-rcvbuf 4MB --tcp-sndbuf 4MB --mtu 1420
```

Add these flags to the `ExecStart` line in `proxygw.service`. Beyond this,
throughput is capped by the proxy provider's plan, not by anything tunable
locally.

## Changing the proxy provider or exit location

The proxy endpoint is entirely defined by `/etc/proxygw.env` on the VM (one
line: `PROXY=socks5://user:pass@host:port`). To switch provider, plan, or
exit country: update that file, then `sudo systemctl restart proxygw` — no
router or VM-network changes are needed, since the router only ever talks
to the VM's LAN IP, never to the proxy directly.
