#!/bin/bash
# Periodic health check for the proxygw tunnel. If traffic through tun0
# isn't actually getting out, restart the service and log it so a real
# failure leaves evidence instead of just quietly self-recovering.
#
# Requires two consecutive failed checks (not one) before restarting, and
# checks two independent endpoints each time - a single flaky CDN response
# shouldn't be enough to trigger a restart on its own. Runs every 20s (see
# proxygw-healthcheck.timer) specifically so a sub-minute WAN/proxy blip has
# a real chance of being sampled instead of falling between 60s-spaced polls.
set -euo pipefail

STATE=/run/proxygw-healthcheck.failcount
FAILS=$(cat "$STATE" 2>/dev/null || echo 0)

check_one() {
    curl -s --interface tun0 --max-time 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null | grep -q '^204$\|^200$'
}

if check_one https://www.gstatic.com/generate_204 || check_one https://1.1.1.1/cdn-cgi/trace; then
    rm -f "$STATE"
    exit 0
fi

FAILS=$((FAILS + 1))
echo "$FAILS" > "$STATE"

if [ "$FAILS" -lt 2 ]; then
    logger -t proxygw-healthcheck "check failed (1/2, not yet restarting) - tun0=$(ip -br link show tun0 2>&1)"
    exit 0
fi

logger -t proxygw-healthcheck "tun0 health check failed twice in a row - restarting proxygw. tun0=$(ip -br link show tun0 2>&1) route-table-100=$(ip route show table 100 2>&1) default-gw-ping=$(ping -c1 -W2 -I tun0 1.1.1.1 2>&1 | tail -1)"
rm -f "$STATE"
systemctl restart proxygw
