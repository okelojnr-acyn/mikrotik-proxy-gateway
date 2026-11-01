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

   **Observed once: 3 failed attempts in a row** (roughly a 1-in-8 chance
   if attempts were truly independent at 50/50) during a session where the
   host was simultaneously running a browser with dozens of tabs, several
   SSH/RDP-style tool sessions, and other CPU-heavy background processes.
   Not proven causal, but consistent with the "host CPU scheduling
   starves the guest's virtual clock" theory — if you're about to do a
   boot-hang-prone power-cycle, closing unnecessary host-side load first
   is a reasonable thing to try before assuming you're just having bad
   luck. The 4th attempt succeeded with no other change made.

   **If the VM boots past this but then sits waiting on
   `systemd-networkd-wait-online.service` indefinitely**: that's not a
   new hang, it's the same dependency this whole project relies on,
   working as designed — `proxygw.service` has
   `After=network-online.target`, so if the VM's bridged NIC has no link
   (e.g. the host's physical cable is out), the VM will boot fine but
   just sit there waiting for a network that can't come up, for as long
   as the link stays down. Reconnect the host's cable and it proceeds on
   its own within a few seconds — no VM-side action needed.

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
Confirmed again later: deliberately using this same command to *simulate*
a VM outage (for testing the router's kill switch) reproduced the exact
same stale-bridge symptom, even though nothing physical was touched at
all. **The trigger is any link-state transition on the host's bridged
NIC, not specifically a physical cable event** — keep that in mind before
using a NIC link toggle for testing anything on this setup, since the
"test" itself can leave you in the broken state it was meant to probe.

**What fixed it:** a full VM power cycle (`poweroff` then `startvm`).

**Prevention:** avoid repeatedly unplugging/replugging the host's physical
Ethernet cable while the gateway VM is running, and avoid using
`setlinkstate1` as a test tool on this setup for the same reason. If you
need an alternate path to manage the router while physically disconnected,
see the next item.

**Lighter alternative, added to `vm-watchdog.ps1` (not yet confirmed to
work reliably)**: toggling the VM's own virtual NIC (`setlinkstate1`) is
confirmed *not* to fix this, but that's a different layer from toggling
the *host's* physical NIC driver binding (`Disable-NetAdapter` /
`Enable-NetAdapter` in Windows, not a cable event or a VM-side command).
That fully unbinds and rebinds the NDIS stack on the host side, including
VirtualBox's bridged-networking filter driver, without touching the VM at
all. The watchdog now tries this first, before falling back to the proven
full power-cycle. Requires admin rights (`/RL HIGHEST` on the scheduled
task) — see `local/REAL-VALUES.md` for the exact setup command.

**Two real bugs found and fixed 2026-11-01**, after the watchdog was
observed power-cycling the VM every ~2 minutes for 45+ minutes straight
with zero recovery — this was not a one-off, it had happened across
multiple earlier sessions too and is the most likely explanation for the
"we fix it, then a few minutes later it's broken again" loop:

1. **The watchdog never checked whether the host's own physical NIC had
   link at all** before trying the light fix or power-cycling. If the
   router/cable is simply unplugged, the host NIC itself is down and
   *nothing* below that layer — not the light fix, not a VM reboot — can
   possibly restore reachability. The watchdog kept trying anyway,
   burning a boot-hang-risk power-cycle every ~2-3 minutes for no
   possible benefit. Fixed: it now checks `Get-NetAdapter` on the host
   NIC first and no-ops (just resets its counters) if it's not `Up`.
2. **The datetime-serialization bug from the 2026-10-31 fix (see item 29
   in `local/session-log.md`) was only actually fixed in the "VM not
   running" code path — the power-cycle fallback path at the bottom of
   the script still did `$state.lastAction = Get-Date` (a raw
   `[datetime]`, not `.ToString("o")`).** `ConvertTo-Json` silently
   corrupts that into a nested object on write, so on the *next* run
   `[datetime]::Parse()` throws, falls back to `[datetime]::MinValue`,
   and the 150s post-action grace window silently never applied after a
   power-cycle specifically. Net effect: after power-cycling the VM, the
   watchdog would check again in ~1 minute — before the VM had any real
   chance to finish booting — see it still unreachable, and immediately
   start counting toward (and often reach) another power-cycle. This can
   produce exactly the "looks fixed, dead again a few minutes later"
   pattern independent of any actual VM/router issue. Fixed: that line
   now also uses `.ToString("o")`, matching the other path.

Both fixes are in `local/vm-watchdog.ps1` (deployed) and mirrored in
`configs/vm-watchdog.ps1.template` (generic).

**Verified live 2026-11-01, with a third bug found along the way**: on
reconnecting the MikroTik, the watchdog correctly no-opped while the host
NIC was still down, then correctly ran light-fix → soft-fail → power-cycle
once link came back — but the *scheduled task itself* turned out to have
been silently failing on every single run since 05:51 that same day
(`LastTaskResult` stuck on the Win32 "process terminated unexpectedly"
code, `NumberOfMissedRuns` climbing). Root cause: the task's logon type
had ended up as `S4U`, which cannot satisfy `RunLevel: Highest` without a
stored password — a well-known broken combination in Windows Task
Scheduler, distinct from the `RunLevel` itself (which was already
correctly set to `Highest`; that part had never been the problem). Fixed
by switching the principal's logon type to `Interactive` (works silently
for an admin user who's always logged in, no password needed — same
no-stored-credential approach as elsewhere in this project):
```powershell
$principal = New-ScheduledTaskPrincipal -UserId "<host>\<user>" -LogonType Interactive -RunLevel Highest
Set-ScheduledTask -TaskName "ProxyGW-VM-Watchdog" -Principal $principal
```
Needs to run from an **elevated** prompt (changing a task principal is a
protected operation). After this, `LastTaskResult` went to `0` and the
watchdog's own automated recovery sequence (light-fix → power-cycle) ran
and completed successfully, unattended, exactly as designed — the VM came
back up and `proxygw`/`tun0`/the router's `via-proxy` route were all
confirmed healthy afterward. The VM boot-hang bug (separate, pre-existing)
still showed up during this same test and needed one manual retry — that
part is unrelated and unfixed, same as always.

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
(script + oneshot service + timer, polling every 20s) actively tests
connectivity through `tun0` against two independent endpoints and restarts
`proxygw` automatically if it's actually down, logging the event via
`logger`. It requires **two consecutive failed polls** before restarting,
not one — a single flaky CDN response isn't enough to trigger a restart on
its own. This won't fix an upstream provider hiccup that resolves on its
own faster than the check interval, but it bounds the worst case to well
under a minute of downtime and — more importantly — leaves a log trail
(`journalctl -t proxygw-healthcheck`) so a *genuinely* recurring problem is
diagnosable instead of anecdotal. On an actual restart, the log line also
includes `tun0` link state, the table-100 route, and a ping-through-tun0
result at that moment, specifically to make a recurring-but-unexplained
pattern easier to pin down next time instead of needing to re-derive it
live.

**Important caveat, found by direct observation**: even a 20s poll
interval can miss a sub-minute WAN flap entirely if the flap starts and
ends between two polls, or resolves within one poll's timeout window — a
clean `journalctl -t proxygw-healthcheck` is evidence the *tunnel* wasn't
down at the moments it happened to check, not proof nothing happened. See
docs/OPERATIONS.md → "Failure modes" for how to tell this apart from an
actual kill-switch event using the router's own WAN interface log instead.

**If it keeps happening:** check `journalctl -t proxygw-healthcheck` for a
pattern (time of day, frequency), and consider disabling QUIC in the
browsers on affected devices as a test (Chrome: `chrome://flags` →
"Experimental QUIC protocol" → Disabled) to see if that specifically
correlates with the symptom.

**Update after enriching the healthcheck's failure logging** (logging
`tun0` link state, the table-100 route, and a ping-through-tun0 result at
the moment of each restart — see `configs/proxygw-healthcheck.sh`): this
revealed the restarts aren't all the same failure. Two distinct patterns
showed up on the same deployment within a few hours of each other:

1. **`tun0` genuinely gone** (`Device "tun0" does not exist`) — the
   `tun2socks` process itself died. A restart is the correct, necessary
   response here.
2. **`tun0` up, the table-100 route present, and a ping through `tun0`
   succeeding** — yet both HTTPS health-check endpoints still failed
   twice in a row, triggering a restart anyway. This is the more
   interesting case: something about opening a *new* SOCKS5-relayed TCP
   connection was failing even though the tunnel's basic plumbing was
   fine. **Caveat on trusting the ping check specifically**: `tun2socks`
   may answer ICMP echo requests itself without actually relaying them
   anywhere — a successful ping through `tun0` is not firm proof the
   proxy path is actually reachable end-to-end, just that the local
   tunnel interface is up. Don't over-read it as confirmation the restart
   was unnecessary.

Two restarts of pattern 2 happened about a minute apart (the first
restart didn't fix whatever caused the second failure right after), and
separately, pattern-1 and pattern-2 events were observed roughly
60-65 minutes apart from each other on the same day — consistent with,
but not confirmed as, the proxy provider's own session/connection cycling
on an hourly-ish cadence. If this is your proxy provider too, and you see
the same pattern, it's worth asking their support about session/connection
lifetime on your plan before assuming it's something local.

---

### A device loses internet, but it's not the WAN and not the gateway VM

**Symptom:** one or more LAN devices lose internet (sometimes a
non-PC/non-gateway device, like a phone through an AP, notices first);
the router's WAN interface log is completely quiet for that window (ruling
out an ISP/WAN glitch — see Operations → "Failure modes"), and the
gateway VM is confirmed healthy throughout.

**Cause found once:** the router's own **LAN-side switch ports**
(`ether2`/`ether3` on this deployment, i.e. the ports forming `BR-LAN`)
flapping — several link down/up cycles in under a minute, coinciding with
a connected AP's DHCP lease getting renewed. This is a third category of
failure distinct from both "WAN glitch" and "gateway VM down" — it's the
router's *LAN* side having a hardware/cabling hiccup, independent of
everything this project's kill switch or healthchecks are watching for.

**How to tell it apart**: check the router's interface log
(`/log print`) for `ether2`/`ether3` (or whichever ports form your LAN
bridge) activity in the relevant window, not just `ether1` (WAN). None of
this project's existing monitoring (the in-VM healthcheck, the host
watchdog, the router's `check-gateway` ping) is positioned to catch this
specifically, since all three only ever check the VM's own reachability,
not the health of the LAN switch ports themselves.

**Fix:** none identified beyond the general "check cabling/AP hardware"
— this reads as a physical-layer issue (cable, port, or the AP itself),
not a configuration problem.

### Routine `apt upgrade` on the gateway VM disrupts the tunnel

**Observed:** running a normal `apt upgrade` with a batch of pending
package updates, the tunnel/LAN connectivity dropped for a few minutes
shortly after the upgrade finished.

**Likely cause:** Ubuntu's `needrestart` (invoked automatically by `apt
upgrade` when it detects libraries used by running services have been
updated) decided to restart `ssh.service`, `systemd-networkd.service`,
and `systemd-resolved.service` together. `tun0` and its routing/iptables
rules are set up by `tun2socks`'s `--tun-post-up` script, not by
`systemd-networkd` directly, so this shouldn't tear `tun0` down — but
restarting the base network stack services it depends on can still cause
a real, if brief, disruption to the whole chain, especially if the host
is already under heavy load (see the boot-hang entry above for why host
load matters here too).

**Not fully confirmed as the sole cause** — treat this as a caution, not
a proven mechanism. **Mitigation:** after any `apt upgrade` on this VM,
explicitly verify the tunnel afterward rather than assuming it's fine
just because `apt` exited cleanly:

```
systemctl is-active proxygw
curl --interface tun0 --max-time 8 https://ip.decodo.com/json
```

If it's broken, `sudo systemctl restart proxygw` re-runs the
`--tun-post-up` script and should recover it without needing a full VM
reboot. Consider doing routine upgrades at a time when a brief
interruption is acceptable, not mid-use.

### Large file downloads getting killed partway through

Background/foreground command execution in most automation shells has a
hard wall-clock timeout (commonly ~10 minutes) independent of whether the
command is "backgrounded" — a multi-GB download over a slow link can get
killed mid-transfer even when the transfer itself was healthy. Resuming
with a tool that supports `Range` requests (`curl -C -`) and launching it
as a fully detached process (so it's not bound to any single command
invocation's timeout) works around this — just poll for completion
separately rather than blocking on it.
