#!/bin/bash
# Run by tun2socks via --tun-post-up once tun0 exists.
# Brings tun0 up, sets up forwarding + the kill switch, and NATs onto tun0.
set -euo pipefail

IF=enp0s3          # LAN-facing interface on the gateway VM - change to match your VM
TUNDEV=tun0

# tun2socks creates tun0 but leaves it administratively down - must bring it
# up ourselves before adding routes that use it as a device.
ip link set "$TUNDEV" up

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.default.rp_filter=0
sysctl -w "net.ipv4.conf.$TUNDEV.rp_filter=0"
sysctl -w "net.ipv4.conf.$IF.rp_filter=0"

# Forwarded LAN traffic (arriving on $IF) goes out tun0 by default.
ip route replace default dev "$TUNDEV" table 100

# Kill switch: if tun0/table 100 has no route (proxy down), forwarded LAN
# traffic is blackholed instead of falling back to any other path.
ip rule del iif "$IF" lookup 100 priority 100 2>/dev/null || true
ip rule add iif "$IF" lookup 100 priority 100
ip rule del iif "$IF" blackhole priority 110 2>/dev/null || true
ip rule add iif "$IF" blackhole priority 110

iptables -t nat -C POSTROUTING -o "$TUNDEV" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$TUNDEV" -j MASQUERADE
iptables -C FORWARD -i "$IF" -o "$TUNDEV" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$IF" -o "$TUNDEV" -j ACCEPT
iptables -C FORWARD -i "$TUNDEV" -o "$IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$TUNDEV" -o "$IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

echo "proxygw-net.sh: routing configured"
