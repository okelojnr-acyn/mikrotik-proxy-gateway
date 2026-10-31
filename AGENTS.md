# Agent notes — home-proxy-gateway

This file is the durable, repo-local context for any AI agent (Claude Code
or otherwise) picking this project back up. It complements — doesn't
replace — the `docs/` folder (which is generic/reproducible) and
`local/` (which has the real, deployment-specific values).

## Before touching anything

1. Read `local/REAL-VALUES.md` — real credentials, IPs, current exit IP,
   and the authoritative "Open items" list. Treat it as ground truth over
   anything in this file or in external memory, since it gets updated
   every session.
2. Read `local/session-log.md` — chronological incident/build history.
   Skim the tail for the most recent entries before assuming you know the
   current state.
3. **Verify live state, don't trust docs alone.** This project runs on
   physical infrastructure (a VM on the user's daily-use PC, a MikroTik
   router) that changes state for reasons outside any doc — cables get
   unplugged, the PC loses power, the VM hits its known boot-hang issue.
   Check actual reachability before making or recommending changes:
   - `ssh -i ~/.ssh/proxygw_key <vm-user>@<vm-lan-ip>` — confirm `proxygw`
     and `proxygw-healthcheck.timer` are `active`, and `tun0` exists.
   - `plink -ssh -pw <pw> admin@<router-lan-ip> -hostkey <fingerprint>
     "<RouterOS command>"` — confirm the `via-proxy` route is active and
     FastTrack is still disabled.
   - Exact values for all of the above are in `local/REAL-VALUES.md`.

## Operational quick reference

- **VM control from the Windows host**: `VBoxManage.exe` at
  `C:\Program Files\Oracle\VirtualBox\VBoxManage.exe` isn't on PATH by
  default — call it by full path, or from PowerShell.
  `startvm <name> --type headless`, `controlvm <name> poweroff`,
  `controlvm <name> setlinkstate1 <off|on>`.
- **The VM's bridge depends on the host's physical NIC having a live
  link.** If the host's Ethernet adapter shows disconnected (cable out,
  router unplugged), the VM's bridged networking goes down even though
  the VM itself is still "running." Reconnecting the cable alone doesn't
  always bring it back — see the next point.
- **Known recurring issue**: after the host physical NIC loses and
  regains link (cable unplug/replug, router power cycle, etc.) — **or
  after any `VBoxManage controlvm <vm> setlinkstate1 off`/`on` toggle,
  even with no physical event at all** (confirmed: deliberately using
  this to simulate a VM outage for testing reproduces the exact same
  bug) — VirtualBox's bridged networking can get stuck even once the
  link is back: the VM pings fine from the host but is unreachable from
  the router/LAN. A NIC link-state toggle does **not** reliably fix this
  (it's often what caused it in the first place). A full VM power-cycle
  (`poweroff` + `startvm`) does. This has recurred across multiple
  sessions — always go straight to the power-cycle, and avoid using
  `setlinkstate1` as a test/simulation tool on this setup since the test
  itself causes the exact failure it's meant to probe.
- **The boot hang (see Troubleshooting) got worse under heavy host
  load**: 3 failed attempts in a row were observed once during a session
  with unusually high host CPU contention (heavy browser/tool usage
  running concurrently). Not proven causal, but if retries are failing
  repeatedly, consider whether the host itself is under unusual load
  before concluding it's just bad luck.
- **A LAN device losing internet isn't always the WAN or the VM** — the
  router's own LAN-side switch ports can flap independently (see
  Troubleshooting → "A device loses internet, but it's not the WAN and
  not the gateway VM"). Check the full interface log, not just the WAN
  port, before assuming which failure mode you're looking at.
- **After any VM/route disruption**, flush RouterOS connection tracking
  for the LAN subnet before considering the fix verified — FastTrack (if
  it were ever re-enabled) and stale conntrack entries can otherwise pin
  traffic to a dead path silently:
  `/ip firewall connection remove [find src-address~"<lan-subnet-prefix>"]`
- **Failure-mode mental model** (see `docs/OPERATIONS.md` → "Failure
  modes" for the full writeup): the router's kill-switch route checks
  reachability to the **VM's LAN IP only**, not the internet. That means:
  - VM/router actually down or unreachable → kill switch engages, LAN
    loses internet cleanly, fails closed. This is the designed behavior.
  - ISP/WAN itself glitches or drops for a bit → the VM is still
    LAN-reachable, so the route stays "up," but the VM's own path to the
    proxy is also dead → traffic just **stalls/times out** rather than
    being cleanly blocked. No leak either way, but don't mistake a stall
    for a kill-switch failure when diagnosing — check the router's WAN
    interface log (`ether1 link down/up`) and the VM's `proxygw-healthcheck`
    journal for timestamps that line up before concluding which failure
    mode you're looking at.
  - **Clocks can differ between devices** — e.g. a MikroTik is commonly
    set to local time while a Linux VM defaults to UTC. Check
    `/system clock print` on the router and `date` on the VM and convert
    before correlating timestamps between the two, or you'll draw wrong
    conclusions about what caused what (this exact mistake happened once
    during this project's own troubleshooting — see `local/session-log.md`
    if you have access to this specific deployment's private notes).

## After making changes

- Update `local/session-log.md` with what happened and why, in the same
  terse chronological style as existing entries — this is what lets a
  future session (interrupted by anything, including a power outage)
  pick up without re-discovering context from scratch.
- Update `local/REAL-VALUES.md` → "Open items" if you fixed one or found
  a new one.
- Never put real credentials/IPs into any file outside `local/` — grep
  for the real values before committing anything, matching how this repo
  was originally built (see `local/session-log.md` item 18).
