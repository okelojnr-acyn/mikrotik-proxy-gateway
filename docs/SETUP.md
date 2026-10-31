# Setup

Written for: Windows host running VirtualBox + a MikroTik router. The same
pattern works with other hypervisors/routers with router-specific
adjustments (see Architecture for the general pattern).

Build and test the VM fully **before** touching the router, so your
internet stays up the entire time you're building. Router changes come
last, and even then are tested on one device before the whole LAN.

## Prerequisites

- A MikroTik (or other router capable of policy-based routing)
- A paid static/non-rotating SOCKS5 proxy (residential or dedicated-ISP
  proxy service) — host, port, username, password
- A hypervisor on a PC that's on the same LAN as the devices you want to
  cover (VirtualBox used here)
- ~3GB disk for an Ubuntu Server ISO + ~10GB for the VM disk

## 1. Create the VM

- Ubuntu Server (LTS), minimal install, **tick "Install OpenSSH server"**
  during setup
- 2GB RAM / 2 vCPU is plenty
- **Network adapter: Bridged**, bound to your *wired* Ethernet adapter —
  bridging over Wi-Fi is unreliable for this
- During the Ubuntu network step, DHCP is fine — the router reserves a
  static lease for it later (step 5)

After install, note the VM's LAN IP and MAC (`ip -br a`, `ip -br link`).

## 2. SSH access

Set up key-based SSH access from your management machine to the VM, and
give yourself passwordless sudo (makes repeated automation much less
error-prone than retyping a password per command):

```
echo "<youruser> ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/<youruser>-nopasswd
sudo chmod 440 /etc/sudoers.d/<youruser>-nopasswd
sudo visudo -c   # validate syntax before trusting it
```

## 3. Install tun2socks

```
curl -L -o /tmp/t2s.zip https://github.com/xjasonlyu/tun2socks/releases/latest/download/tun2socks-linux-amd64.zip
cd /tmp && unzip -o t2s.zip
sudo install tun2socks-linux-amd64 /usr/local/bin/tun2socks
tun2socks -v
```

## 4. Test the proxy directly before wiring anything up

```
curl -x "socks5h://USER:PASS@HOST:PORT" https://ip.decodo.com/json
```

(Any "what's my IP" JSON endpoint works — Decodo's is used here since
that's the provider in this deployment. Confirm the IP is the same across
repeated requests, i.e. actually static.)

## 5. Deploy the gateway service

Copy `configs/proxygw-net.sh` to `/usr/local/bin/proxygw-net.sh` (root,
mode 755), fill in your proxy credentials in a copy of
`configs/decodo.env.example` and install it as `/etc/proxygw.env` (root,
mode 600 — it holds a plaintext password), and install
`configs/proxygw.service.template` as `/etc/systemd/system/proxygw.service`.

```
sudo install -o root -g root -m 755 proxygw-net.sh /usr/local/bin/proxygw-net.sh
sudo install -o root -g root -m 600 proxygw.env /etc/proxygw.env
sudo install -o root -g root -m 644 proxygw.service /etc/systemd/system/proxygw.service
sudo systemctl daemon-reload
sudo systemctl enable --now proxygw
sudo systemctl status proxygw --no-pager
```

### Watchdog (recommended)

Proxy tunnels occasionally hiccup for reasons outside this setup's control
(a brief blip on the provider's end, a flaky UDP/QUIC-heavy site, etc.).
Rather than rely on manually noticing and restarting the service, install a
health check that runs every minute and restarts `proxygw` automatically if
traffic genuinely isn't getting out — and logs the event, so a real
recurring problem leaves evidence instead of just quietly fixing itself
each time:

```
sudo install -o root -g root -m 755 proxygw-healthcheck.sh /usr/local/bin/proxygw-healthcheck.sh
sudo install -o root -g root -m 644 proxygw-healthcheck.service /etc/systemd/system/proxygw-healthcheck.service
sudo install -o root -g root -m 644 proxygw-healthcheck.timer /etc/systemd/system/proxygw-healthcheck.timer
sudo systemctl daemon-reload
sudo systemctl enable --now proxygw-healthcheck.timer
```

Check whether it's ever actually fired: `journalctl -t proxygw-healthcheck`
— no output means it's never needed to intervene.

Verify traffic actually flows through `tun0` specifically (not just the
VM's normal route):

```
curl --interface tun0 https://ip.decodo.com/json
```

Check the kill switch works before moving on:

```
sudo systemctl stop proxygw
curl --interface tun0 --max-time 5 https://ip.decodo.com/json   # should fail/time out, not leak
sudo systemctl start proxygw
```

## 6. Auto-start the VM with the host

On the Windows host, a scheduled task triggered **at logon** (not "at
startup" — avoids needing to store the Windows account password) starts the
VM headless:

```
schtasks /create /tn "StartProxyGW" /tr "\"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe\" startvm \"<vm-name>\" --type headless" /sc onlogon /rl limited /f
```

> PowerShell quoting note: backslash is not an escape character in
> PowerShell (unlike cmd). If pasting the above into PowerShell directly,
> prefix it with the stop-parsing token so it's passed through literally:
> `schtasks --% /create /tn ...`

Test by actually logging off and back on — `schtasks /run` does not
reliably reproduce the real logon-triggered session attachment, so it's not
a trustworthy test on its own.

## 7. Router configuration (do this last)

Adjust the example `172.16.50.0/24` / `172.16.50.237` values in
`configs/mikrotik-setup.rsc.template` to your actual LAN subnet and VM IP,
then apply via SSH/Winbox/terminal, in this order:

1. **Reserve the VM's DHCP lease as static** — it becomes a routing gateway,
   it cannot be allowed to change IP.
2. **Create the `via-proxy` routing table and default route** pointing at
   the VM, with `check-gateway=ping` so the router knows when it's down.
3. **Add exemption rules** (routed-rule priority matters — these must come
   before the catch-all): the VM's own traffic uses `main` directly; LAN
   intra-subnet traffic stays local.
4. **Disable FastTrack** and flush `/ip firewall connection` for the LAN —
   required, see Architecture for why.
5. **Disable the DNS dst-nat redirect** for the LAN interface, if one
   exists — required to avoid a DNS leak, see Architecture.
6. **Test on one device** with a scoped routing rule before the whole LAN
   (see Operations → "Rolling out gradually").
7. Once verified, replace the test rule with the whole-subnet rule.

## 8. Verify end to end

- From a LAN device (not the gateway VM itself): an IP-check site shows the
  proxy's location, consistently, across repeated checks.
- DNS leak check: `nslookup -type=TXT o-o.myaddr.l.google.com. 8.8.8.8` —
  the `edns0-client-subnet` in the response should be the proxy's IP range.
- Kill switch: stop the `proxygw` service on the VM, confirm LAN devices
  lose internet (not leak); restart it, confirm recovery.
- Reboot the VM, confirm the service and routing come back automatically.
