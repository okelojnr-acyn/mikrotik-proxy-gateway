# Troubleshooting

Real issues hit while building this setup, and what fixed them. Organized
by symptom.

---

### VM hangs on boot at `Loading essential drivers...`

**Symptom:** console/screenshot shows kernel boot log frozen on this exact
line, CPU pegged on one core, no progress for many minutes.

**Two different causes found:**

1. **The install ISO was still the first boot device.** After installing,
   if the virtual DVD stays attached with boot order `dvd, disk`, every
   power cycle re-boots the live installer image, not the installed system.
   Hot-ejecting an IDE-attached virtual DVD isn't supported while the VM is
   running (`VBoxManage ... error: Controller 'IDE Controller' does not
   support hot-plugging`) — power the VM off first, then detach the ISO and
   set `boot1=disk`.

2. **Intermittent, ~50% of cold boots, even with the ISO removed.** Looks
   like host CPU scheduling jitter — the hung boot log sometimes shows
   `clocksource: Long readout interval, skipping watchdog check`, a known
   symptom of the VM's virtual clock getting starved by host scheduling
   delays, which can cascade into an early-boot hang. Also saw
   `drm_fb_helper_damage_work hogged CPU` warnings right before some hangs;
   adding the `nomodeset` kernel parameter (disables the framebuffer/DRM
   console) did **not** fix the underlying issue — a reboot still hung
   afterward under the exact same symptoms, just via a different trigger
   path (a guest-initiated `reboot`, not even headless-specific). This
   means it isn't a graphics-driver bug specifically.

   **No permanent fix found.** Workaround: power off, start again. Success
   rate is roughly 50/50 per attempt, so 2-3 retries reliably gets a clean
   boot. Once a boot succeeds, the system is stable — this is strictly an
   early-boot issue, not an ongoing one.

---

### `tun2socks --tun-post-up` script fails: `Error: Device for nexthop is not up`

**Cause:** `tun2socks` creates the `tun0` device but leaves it
administratively **down** — it does not bring the link up itself.

**Fix:** the post-up script must bring the interface up as its first
action, before adding any route that uses it as a device:

```sh
ip link set tun0 up
```

---

### A LAN device's IP check suddenly shows the real ISP, not the proxy

This is a leak — treat it as urgent. Two confirmed causes:

**1. RouterOS FastTrack bypassing policy routing.** FastTrack accelerates
*established* connections by skipping firewall *and routing-rule*
evaluation on subsequent packets — using whatever route was decided when
the connection first became established. Any connection established
*before* a routing-rule change keeps using its old route indefinitely,
silently, even though new rules look correct in `/routing rule print`.

Check the FastTrack rule's hit counters — a large, climbing packet count
confirms it's active and likely responsible:

```
/ip firewall filter print stats where chain=forward
```

**Fix:**

```
/ip firewall filter disable [find action=fasttrack-connection]
/ip firewall connection remove [find src-address~"<affected-subnet-prefix>"]
```

Do the connection flush every time you change routing rules while testing,
not just once — otherwise you'll keep seeing stale results and think a fix
didn't work when it actually did.

**2. DNS leak independent of the IP routing being correct.** If the router
has a transparent DNS redirect (`dst-nat` of port 53 to the router itself)
for the LAN interface, DNS gets resolved by the *router*, using the
router's own path — regardless of what route the client's other traffic
takes. Browsing IP shows the proxy's country; DNS resolver metadata still
shows your real one. Disable the redirect NAT rule(s) for that interface;
see Architecture for the full explanation and a verification command.

---

### VM is "running" (per VirtualBox) and fully booted, but unreachable from the router or anywhere off the host

**Cause observed:** VirtualBox's bridged networking can get into a stale
state after the *host's* physical NIC goes through a link down/up event
(e.g. someone unplugs/replugs the Ethernet cable on the host PC). The VM
itself is fine — pinging it **from the host** can even succeed — but
traffic from anywhere beyond the host (like the router) doesn't reach it.

**What didn't fully/reliably fix it:** toggling the VM's virtual NIC link
state alone (`VBoxManage controlvm <vm> setlinkstate1 off` then `on`).

**What fixed it:** a full VM power cycle (`poweroff` then `startvm`).

**Prevention:** avoid repeatedly unplugging/replugging the host's physical
Ethernet cable while the gateway VM is running. If you need an alternate
path to manage the router while physically disconnected, see the next
item.

---

### Need to reach the router but the host's LAN cable is unplugged

If the router's WAN-side interface happens to be on the same subnet as
another network your management machine can still reach (e.g. both are on
the ISP router's network in a double-NAT setup), you can often reach the
router's WAN IP directly over that other path (e.g. Wi-Fi) — no need to
keep plugging/unplugging a cable to issue router commands. Check
`/ip address print` on the router for an address on a subnet you can
already reach another way.

---

### PowerShell: commands with nested double quotes fail or misparse

**Cause:** PowerShell does **not** treat backslash as an escape character
(unlike `cmd.exe`/bash). A string like
`"... \"C:\Program Files\...\" ..."` does not mean what it looks like it
means — the `\"` sequence ends the PowerShell string early, and the rest
gets tokenized as bare words (classic symptom: `Invalid argument/option -
'C:\Program'`).

**Fixes, in order of preference:**
- Avoid the nesting: write the command to a small script file instead of
  inlining it, and execute the file.
- Use PowerShell's own escape character (backtick) for embedded quotes
  instead of backslash: `` `" ``.
- For passing a complex native-command line through unmodified (as if from
  `cmd.exe`), use the stop-parsing token: `command --% rest of line here`
  — everything after `--%` is passed through literally.

---

### Scheduled task / firewall rule creation fails with "Access is denied" despite the account being an Administrator

**Cause:** Windows UAC strips admin rights from any non-elevated process
token, even for accounts in the Administrators group (the group shows up
as "deny only" in `whoami /groups` for a non-elevated process). Some
operations — Task Scheduler root-folder task creation among them — refuse
outright for this filtered token rather than silently degrading.

**Fix:** run the specific command from an explicitly elevated session
("Run as Administrator"), not just an administrator account's normal
session.

---

### Testing from the gateway-host PC itself gives misleading results

The PC running the hypervisor often has multiple active network paths at
once — Wi-Fi, the wired/gateway-routed Ethernet, and potentially a VPN/
tunnel client (e.g. Cloudflare WARP) that intercepts traffic below the
normal OS routing table. Any of these can silently win over the path
you're trying to test, producing results that look like your proxy setup
is broken (or, worse, look like it's working when it isn't really being
exercised).

**Fix:** when testing specifically whether *router→gateway→proxy* routing
works, disconnect/disable every other outbound path on the test machine
first (Wi-Fi, VPN clients) so the path under test is the only option.
Binding a test tool to a specific local IP (e.g. `curl --interface <ip>`)
is not a reliable substitute on Windows when multiple default routes
exist — it can fail with a generic socket error (`Bad access`) rather than
actually forcing the path.

---

### `schtasks /run` doesn't prove a logon-triggered task actually works

Manually firing an "At logon" scheduled task with `schtasks /run` can
report success (`Last Result: 0`) without the triggered program actually
starting correctly — logon-triggered tasks are meant to attach to a real
interactive logon session, which a manual `/run` from an already-elevated
session doesn't reproduce faithfully. Test by actually logging off and
back on, not by `/run`.

---

### Brief, self-resolving outages (a site stops loading for a minute, then works again)

**Symptom:** a device on the LAN loses internet for roughly a minute and
then it's back on its own, with nothing obviously wrong afterward — the
`proxygw` service shows continuous uptime (no restart), the router's
`via-proxy` route is active, and a manual test moments later succeeds
cleanly.

**Likely causes** (hard to pin down precisely after the fact, since by the
time you can check, it's already recovered):
- A brief hiccup on the proxy provider's end — outside this setup's
  control.
- UDP/QUIC handling through the SOCKS5 tunnel. Sites that lean heavily on
  QUIC (YouTube, Google in general) can stall until the browser falls back
  to plain TCP, which looks like a temporary outage from the user's side
  even though the tunnel itself never went down. SOCKS5-over-TUN UDP
  support is a known soft spot for this class of setup.
- Host scheduling jitter (see the boot-hang entry above) causing a brief
  window of degraded VM networking without a full outage.

**Mitigation shipped in this repo:** `configs/proxygw-healthcheck.*`
(script + oneshot service + 1-minute timer) actively tests connectivity
through `tun0` and restarts `proxygw` automatically if it's actually down,
logging the event via `logger`. This won't fix an upstream provider hiccup
that resolves on its own faster than the check interval, but it bounds the
worst case to about a minute of downtime and — more importantly — leaves a
log trail (`journalctl -t proxygw-healthcheck`) so a *genuinely* recurring
problem is diagnosable instead of anecdotal.

**If it keeps happening:** check `journalctl -t proxygw-healthcheck` for a
pattern (time of day, frequency), and consider disabling QUIC in the
browsers on affected devices as a test (Chrome: `chrome://flags` →
"Experimental QUIC protocol" → Disabled) to see if that specifically
correlates with the symptom.

---

### Large file downloads getting killed partway through

Background/foreground command execution in most automation shells has a
hard wall-clock timeout (commonly ~10 minutes) independent of whether the
command is "backgrounded" — a multi-GB download over a slow link can get
killed mid-transfer even when the transfer itself was healthy. Resuming
with a tool that supports `Range` requests (`curl -C -`) and launching it
as a fully detached process (so it's not bound to any single command
invocation's timeout) works around this — just poll for completion
separately rather than blocking on it.
