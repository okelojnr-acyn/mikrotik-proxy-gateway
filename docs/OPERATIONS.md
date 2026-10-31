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
