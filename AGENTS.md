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
  regains link (cable unplug/replug, router power cycle, etc.),
  VirtualBox's bridged networking can get stuck even once the link is
  back — the VM pings fine from the host but is unreachable from the
  router/LAN. A NIC link-state toggle (`setlinkstate1 off` then `on`)
  does **not** reliably fix this. A full VM power-cycle
  (`poweroff` + `startvm`) does. This has recurred across multiple
  sessions — always try the power-cycle directly rather than spending
  time on the link toggle first.
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
