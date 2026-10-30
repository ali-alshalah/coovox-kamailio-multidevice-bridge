#!/usr/bin/env bash
# Restore Kamailio/RTPengine config and SQLite contact DB from a trusted local backup.
# Requires operator confirmation because SIP sessions may be disrupted.
set -eo pipefail
if [ "$(id -u)" -ne 0 ]; then echo 'Run as root' >&2; exit 1; fi
src="${1:-}"
if [ -z "$src" ] || [ ! -d "$src" ]; then
    echo 'Usage: sudo scripts/rollback.sh /root/backups/<trusted-snapshot>' >&2
    exit 2
fi
for file in "$src/config/coovox.cfg" "$src/config/rtpengine.conf" "$src/db/registered-contacts.sqlite" "$src/SHA256SUMS"; do
    if [ ! -f "$file" ]; then echo "Missing required file: $file" >&2; exit 3; fi
done
(cd "$src" && sha256sum -c SHA256SUMS)
echo 'CAUTION: this stops Kamailio, may drop active SIP calls, and restores old contacts.'
echo 'VPN and firewall are not changed by this script.'
read -r -p 'Type RESTORE to continue: ' answer
[ "$answer" = RESTORE ] || exit 4
# Validate the backup before changing the active config.
kamailio -c -f "$src/config/coovox.cfg"
systemctl stop coovox-kamailio
cp -a "$src/config/coovox.cfg" /etc/kamailio/coovox.cfg
cp -a "$src/config/rtpengine.conf" /etc/rtpengine/coovox.conf
cp -a "$src/db/registered-contacts.sqlite" /var/lib/coovox-sip/registered-contacts.sqlite
chown kamailio:kamailio /var/lib/coovox-sip/registered-contacts.sqlite
chmod 640 /var/lib/coovox-sip/registered-contacts.sqlite
systemctl start coovox-kamailio
systemctl is-active coovox-kamailio
printf 'Kamailio restored. If RTP config actually changed, schedule a separate RTPengine restart.\n'
