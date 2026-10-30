#!/usr/bin/env bash
# Safe/read-only health check; does not restart or edit services.
set -eo pipefail
printf '\nCooVox ↔ Kamailio health: %s\n' "$(date -Is)"
for service in coovox-kamailio coovox-rtpengine openvpn-server@coovox; do
    printf '%-32s: %s\n' "$service" "$(systemctl is-active "$service" 2>/dev/null || true)"
done
printf '\nKamailio syntax check:\n'
if command -v kamailio >/dev/null; then
    kamailio -c -f /etc/kamailio/coovox.cfg 2>&1 | grep 'config file ok' || true
fi
printf '\nLocal RPC table entries (extension IDs only):\n'
if command -v kamcmd >/dev/null; then
    for table in reg regmulti; do
        printf '%s: ' "$table"
        kamcmd -s unix:/var/lib/coovox-sip/kamailio_ctl htable.dump "$table" 2>/dev/null | \
          grep 'name:' | sed 's/.*name: //' | paste -sd ',' - || true
    done
fi
printf '\nUDP listeners of interest:\n'
ss -Hlun 2>/dev/null | grep -E ':(17060|17061|17062|22231) ' || true
printf '\nWarning/error counts in last 5 minutes:\n'
for term in 'REGISTER Rate Limited' 'Ran out of ports' 'CooVox SIP guard: denied'; do
    count="$(journalctl -u coovox-kamailio --since '5 minutes ago' --no-pager 2>/dev/null | grep -Fc "$term" || true)"
    printf '%-36s %s\n' "$term" "$count"
done
printf '\nDo a real 2-way audio test separately; this script cannot test user devices.\n'
