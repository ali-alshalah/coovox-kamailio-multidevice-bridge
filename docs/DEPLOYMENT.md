# Deployment Guide — reproduce the v1.0.0 SIP bridge

**Do not deploy to a production PBX without a verified local rollback point.** These instructions describe an existing topology, not a fully automatic PBX installer. The provided templates have *no credentials* and assume an independently configured OpenVPN server, PBX and firewall.

## 1. Prerequisites

- Ubuntu 24.04 LTS, root/sudo and adequate disk space.
- Kamailio 5.7.x with modules used by `templates/kamailio/coovox.cfg.tpl`, including `htable`, `db_sqlite`, `tm`, `rr`, `sl`, `rtpengine`, `pike`, `sanity`, `siputils`, `corex`, `ctl` and `xlog`.
- RTPengine 11.5.x, a dedicated service user, public and VPN interfaces, unused media UDP range 22000–23999.
- OpenVPN 2.6 server and a *separate* VPN client configuration on the PBX; verify the PBX's SIP server is reachable through the tunnel.
- Firewall/NAT support through iptables-nft (matching the reference deployment).
- SQLite3 and Python 3.12+ (the template rendering script uses no external Python libraries).
- CooVox extension(s) in the configured numbering plan `100–199`. Set the PBX's allowed simultaneous registrations high enough for actual clients.

Reference installed apt packages:

```bash
sudo apt update
sudo apt install kamailio kamailio-extra-modules kamailio-sqlite-modules \
  rtpengine-daemon openvpn sqlite3 python3 iptables
```

Check installed versions and services rather than forcing upgrades on a working host. On a dedicated host, avoid binding competing default `kamailio.service` or `rtpengine-daemon.service` to the same ports; use the custom unit names from this project only after checking for existing usage.

## 2. Configure locally; never commit real values

```bash
git clone https://github.com/ali-alshalah/coovox-kamailio-multidevice-bridge.git
cd coovox-kamailio-multidevice-bridge
cp .env.example .env
chmod 600 .env
$EDITOR .env
python3 scripts/render_config.py --env .env --output build
```

`.env` must contain:

```env
SIP_PUBLIC_IP=203.0.113.10
SIP_PUBLIC_HOST=sip.example.com
VPN_SERVER_IP=10.9.0.1
PBX_VPN_IP=10.9.0.2
```

These are **documentation addresses**, not usable production values. The `build/` directory is ignored by Git; do not share it if you rendered real IPs. The renderer produces Kamailio, RTPengine and network-script outputs. All four values must refer to your own infrastructure.

## 3. Verify network and routing first

1. Ensure the PBX is reachable via its VPN IP and `:5060` before deploying the proxy.
2. Decide which host IP is public and which is the VPN tunnel address.
3. Confirm UDP `15060` is redirected to local Kamailio UDP `17060`, **with the REDIRECT rule ahead of the legacy DNAT rule**. The proxy path is the intended active path; the old direct DNAT is for contingency only.
4. Allow public SIP, RTPengine's media range, VPN listener, and permitted tunnel traffic as appropriate for your environment. Do not publish private VPN ports to the public Internet.
5. Avoid conflicting Asterisk/RTP ranges on the same VPS.

Inspect the current rules before editing:

```bash
sudo iptables -t nat -S PREROUTING
sudo nft list chain ip nat PREROUTING
sudo ss -lunp
sudo ip link show
```

Network templates under `templates/network/` capture the reference persistence logic. They are **not automatically executed by the renderer**. The `-LEGACY` files document fallback forwarding, not a second proxy route to enable concurrently. Changing firewall rules remotely can cut off administrative access; maintain an out-of-band way back before touching them.

## 4. Initialize local persistence

Create the storage directory owned by the Kamailio user and an SQLite file with these table shapes:

```bash
sudo install -d -o kamailio -g kamailio -m 750 /var/lib/coovox-sip
sudo sqlite3 /var/lib/coovox-sip/registered-contacts.sqlite <<'SQL'
CREATE TABLE IF NOT EXISTS coovox_contacts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key_name TEXT NOT NULL,
  key_type INTEGER NOT NULL DEFAULT 0,
  value_type INTEGER NOT NULL DEFAULT 0,
  key_value TEXT NOT NULL,
  expires INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_coovox_contacts_name ON coovox_contacts(key_name);
CREATE TABLE IF NOT EXISTS coovox_multi_contacts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key_name TEXT NOT NULL,
  key_type INTEGER NOT NULL DEFAULT 0,
  value_type INTEGER NOT NULL DEFAULT 0,
  key_value TEXT NOT NULL,
  expires INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_coovox_multi_contacts_name ON coovox_multi_contacts(key_name);
SQL
sudo chown kamailio:kamailio /var/lib/coovox-sip/registered-contacts.sqlite
sudo chmod 640 /var/lib/coovox-sip/registered-contacts.sqlite
```

Do not overwrite an existing production SQLite DB with an empty one. On upgrade, use `scripts/backup.sh` first and verify backups and schema. SQLite contacts are runtime data and must never be committed.

## 5. Deploy only after syntax and backup checks

```bash
# On existing production first:
sudo ./scripts/backup.sh

# Validate the rendered *candidate*:
sudo kamailio -c -f build/coovox.cfg

# Verify no active call before any service restart.
# Schedule a controlled maintenance window.
sudo install -o root -g kamailio -m 640 build/coovox.cfg /etc/kamailio/coovox.cfg
sudo install -o root -g rtpengine -m 640 build/rtpengine.conf /etc/rtpengine/coovox.conf
```

If deploying onto a new dedicated host, also install the custom systemd units from `templates/systemd/` **after reading and adapting the dependency graph and service paths**. On an existing VPS, do not replace its service units indiscriminately. The production unit runs Kamailio with `-f /etc/kamailio/coovox.cfg` and RTPengine with `--config-file=/etc/rtpengine/coovox.conf`.

Reload service definitions only if you changed them, then restart the specific impacted service in a maintenance window:

```bash
sudo systemctl daemon-reload             # only if units were changed
sudo systemctl restart coovox-kamailio   # affects SIP transaction state
sudo systemctl is-active coovox-kamailio coovox-rtpengine openvpn-server@coovox
```

If the RTPengine config changed, plan a **separate** restart. Restarting RTPengine can disrupt existing audio. If only Kamailio changed, leave RTPengine running.

## 6. PBX and endpoint settings

- CooVox should have an enabled numeric extension and a correct SIP password. The PBX authenticates REGISTER.
- The extension's `Number Of Simultaneous Registrations` must accommodate all devices; the reference extension `100` was set to **5**.
- Fanvil and MicroSIP use public SIP host / UDP `15060`, numeric username and corresponding auth username; no SIP Proxy is required unless your environment specifically uses one.
- CooCall may use `app_100` and a distinct internal VPN egress socket; keep the branch logic.
- Do not publish or paste passwords into documentation or issues.

## 7. Accept the release only after end-to-end tests

```bash
sudo ./scripts/check-health.sh
sudo journalctl -u coovox-kamailio --since '5 minutes ago' --no-pager
sudo kamcmd -s unix:/var/lib/coovox-sip/kamailio_ctl htable.dump regmulti
```

Test at minimum: two normal SIP devices + CooCall on the same extension, successful REGISTER, outgoing calls, incoming parallel ringing, answering on each device in turn, cancellation of losing branches, audio both ways, and new REGISTER after a NAT/port change. Observe UDP source IP of every fork: it must be the **public** Kamailio address. Review [TESTING.md](TESTING.md).

## 8. Rollback

Use the private local snapshot made *before* changing production:

```bash
sudo ./scripts/rollback.sh /root/backups/<trusted-snapshot>
```

The script requires confirmation and restores the Kamailio config, RTPengine config file and SQLite contacts; it restarts Kamailio but not OpenVPN, firewall, or RTPengine. More detail: [RESTORE.md](RESTORE.md).
