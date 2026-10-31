#!/bin/bash
# Periodic health check for the proxygw tunnel. If traffic through tun0
# isn't actually getting out, restart the service and log it so a real
# failure leaves evidence instead of just quietly self-recovering.
if curl -s --interface tun0 --max-time 6 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 | grep -q '^204$'; then
    exit 0
fi

logger -t proxygw-healthcheck "tun0 health check failed - restarting proxygw"
systemctl restart proxygw
