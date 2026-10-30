#!/usr/bin/env bash
# Local, private rollback point before a change; no GitHub upload.
set -eo pipefail
if [ "$(id -u)" -ne 0 ]; then echo 'Run as root' >&2; exit 1; fi
umask 077
stamp="$(date +%Y%m%dT%H%M%S)"
dest="${1:-/root/backups/coovox-manual-$stamp}"
if [ -e "$dest" ]; then echo 'Backup destination already exists' >&2; exit 2; fi
mkdir -p "$dest"/{config,db,metadata}
cp -a /etc/kamailio/coovox.cfg "$dest/config/coovox.cfg"
cp -a /etc/rtpengine/coovox.conf "$dest/config/rtpengine.conf"
# A graceful Kamailio shutdown also flushes dbmode=1 hash tables.
# For a live snapshot, explicitly flush the registration tables when possible.
for tab in reg regmulti; do
    kamcmd -s unix:/var/lib/coovox-sip/kamailio_ctl htable.store "$tab" >/dev/null 2>&1 || \
        echo "WARNING: could not flush $tab; DB snapshot may be behind live memory" >&2
done
sqlite3 /var/lib/coovox-sip/registered-contacts.sqlite ".backup '$dest/db/registered-contacts.sqlite'"
status="$(sqlite3 "$dest/db/registered-contacts.sqlite" 'PRAGMA integrity_check;')"
if [ "$status" != ok ]; then echo 'SQLite integrity check failed' >&2; exit 3; fi
systemctl is-active coovox-kamailio coovox-rtpengine openvpn-server@coovox > "$dest/metadata/service-state.txt" || true
printf 'Private local CooVox rollback point; not a full VM image.\n%s\n' "$(date -Is)" > "$dest/README.txt"
(cd "$dest" && find config db metadata -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
chmod -R go-rwx "$dest"
echo "Local backup ready: $dest"
echo 'Never upload this directory to a public repository.'
