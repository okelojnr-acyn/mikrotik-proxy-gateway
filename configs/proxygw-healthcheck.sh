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
else
    FAILS=$((FAILS + 1))
    echo "$FAILS" > "$STATE"

    if [ "$FAILS" -lt 2 ]; then
        logger -t proxygw-healthcheck "check failed (1/2, not yet restarting) - tun0=$(ip -br link show tun0 2>&1)"
        exit 0
    fi

    logger -t proxygw-healthcheck "tun0 health check failed twice in a row - restarting proxygw. tun0=$(ip -br link show tun0 2>&1) route-table-100=$(ip route show table 100 2>&1) default-gw-ping=$(ping -c1 -W2 -I tun0 1.1.1.1 2>&1 | tail -1)"
    rm -f "$STATE"
    systemctl restart proxygw
    exit 0
fi

# --- Throughput check (added 2026-10-31) ---
# The reachability check above only confirms a tiny 204 response comes back
# within 5s - it can't tell "healthy" apart from "technically up but
# severely degraded". Found live: tun2socks can survive in a state that
# passes every reachability check yet only delivers a fraction of normal
# throughput (observed ~2.2 Mbit/s vs. a normal ~9-11.5 Mbit/s baseline,
# after the process endured repeated restarts/network flaps). A plain
# `systemctl restart proxygw` fully fixed it, so it's worth automating -
# but a throughput test is comparatively expensive/bandwidth-heavy, so this
# only runs once every $THROUGHPUT_INTERVAL seconds (not every 20s tick),
# and requires two consecutive slow results (spaced that far apart, so
# ~20 min of sustained degradation) before acting - a single slow sample
# could just be normal provider/network variance, not a real fault.
THROUGHPUT_INTERVAL=600      # only sample this often (seconds)
THROUGHPUT_MIN_BYTES_SEC=500000   # ~4 Mbit/s - comfortably below the ~9-11.5 Mbit/s healthy baseline, comfortably above the ~2.2 Mbit/s degraded case actually observed
THROUGHPUT_LAST=/run/proxygw-healthcheck.throughput-last
THROUGHPUT_FAILS=/run/proxygw-healthcheck.throughput-failcount

NOW=$(date +%s)
LAST=$(cat "$THROUGHPUT_LAST" 2>/dev/null || echo 0)
if [ $((NOW - LAST)) -lt "$THROUGHPUT_INTERVAL" ]; then
    exit 0
fi
echo "$NOW" > "$THROUGHPUT_LAST"

SPEED=$(curl --interface tun0 --max-time 10 -s -o /dev/null -w '%{speed_download}' "https://speed.cloudflare.com/__down?bytes=1000000" 2>/dev/null || echo 0)
SPEED=${SPEED%.*}   # curl prints a float; truncate to an integer for comparison

if [ -z "$SPEED" ] || [ "$SPEED" -ge "$THROUGHPUT_MIN_BYTES_SEC" ]; then
    rm -f "$THROUGHPUT_FAILS"
    exit 0
fi

TFAILS=$(( $(cat "$THROUGHPUT_FAILS" 2>/dev/null || echo 0) + 1 ))
echo "$TFAILS" > "$THROUGHPUT_FAILS"

if [ "$TFAILS" -lt 2 ]; then
    logger -t proxygw-healthcheck "throughput check slow (1/2, not yet restarting) - ${SPEED} bytes/s < ${THROUGHPUT_MIN_BYTES_SEC} threshold"
    exit 0
fi

logger -t proxygw-healthcheck "throughput check slow twice in a row (~${THROUGHPUT_INTERVAL}s apart) - restarting proxygw. ${SPEED} bytes/s < ${THROUGHPUT_MIN_BYTES_SEC} threshold"
rm -f "$THROUGHPUT_FAILS"
systemctl restart proxygw
