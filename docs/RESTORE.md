# Restore & Recovery — v1.0.0

A Git tag preserves *source templates*. A **private server checkpoint** is required to restore the running service exactly (real IPs, SQLite contact state, operating-unit files and network state). Do not confuse a public GitHub repository with a complete disaster-recovery image.

## Baseline definition

- Version: `v1.0.0`, 2026-10-30.
- Proven working outcome: extension `100` registered on multiple devices, could call out, and rang concurrently on a Fanvil X303W, MicroSIP and CooCall when dialed by another extension.
- Key regression fix: `branch_route[PUBLIC_FORK]` chooses the **public** send socket for every TM branch of a PBX-originated INVITE.
- The private checkpoint on the original VPS was created separately; do **not** upload or publish the SQLite file or production values.

## Before attempting a repair

1. Check service status (`coovox-kamailio`, `coovox-rtpengine`, `openvpn-server@coovox`) and basic SIP health.
2. Separate registration failure (`401`, `503`, Timeout) from incoming call forking failure (REGISTER `200 OK` but no ring).
3. Preserve logs for analysis on the protected host. If capturing SIP, limit packet count and retention, and protect the output as confidential.
4. Create **another** backup of the current state, even if it is malfunctioning, so you can compare and undo attempted repairs.
5. Compare `sha256sum /etc/kamailio/coovox.cfg` with the known-good checkpoint.

## Restoring a trusted local checkpoint

A snapshot created with `scripts/backup.sh` contains:

```text
<snapshot>/
  config/coovox.cfg
  config/rtpengine.conf
  db/registered-contacts.sqlite
  metadata/service-state.txt
  SHA256SUMS
```

To restore it safely:

```bash
sudo ./scripts/rollback.sh /root/backups/<trusted-snapshot>
```

This verifies checksums, validates Kamailio config syntax, asks for an explicit confirmation, stops the proxy, replaces the config/database, and starts the proxy again. It does not change external firewall policy, OpenVPN certificates, or host networking. If you changed *any* of those, use the separate verified private backup of that part.

After rollback:

```bash
sudo systemctl is-active coovox-kamailio coovox-rtpengine openvpn-server@coovox
sudo kamailio -c -f /etc/kamailio/coovox.cfg
sudo ./scripts/check-health.sh
```

If this was an old snapshot, contacts may point to expired NAT ports; force endpoints to register again without modifying passwords, then retest an outgoing and incoming call.

## Rebuilding from the GitHub release instead

```bash
git fetch --tags
git checkout v1.0.0
cp .env.example .env
# Fill your OWN production settings (keep file private).
python3 scripts/render_config.py --env .env --output build
kamailio -c -f build/coovox.cfg
```

This only produces configuration files. It does **not** restore live SQLite registrations, PBX settings, OpenVPN identity or firewall state; those must come from a private secure backup. Rebuilding from GitHub requires a working VPN and compatible PBX.

## Failure-specific recovery

| Problem | Targeted action | Avoid |
|---|---|---|
| Fanvil not ringing while registered | Verify branch-level public SIP source socket; restore `PUBLIC_FORK` | Changing working SIP password |
| One device replaces another | Restore `regmulti` and inbound fork; verify PBX simultaneous registration limit | Deleting the extension |
| All phones show `503` | Inspect `regipwindow` and `regiplimit` / source IP grouping | Disabling SIP security globally |
| REGISTER after Digest gets repeated `401` | Check PBX account configuration and credentials | Copying or publishing credentials |
| `Ran out of ports` in RTPengine | Reject unauthorized INVITE before media allocation; examine media sessions | Restarting RTPengine while users are talking |
| No VPN | Inspect OpenVPN link, client, routes and MTU | Changing firewall and SIP code at once |
| Call recording missing | Investigate PBX audio recording subsystem separately | Assuming SIP proxy records calls |

## Release promotion policy

A new version should only replace `v1.0.0` as the recommended baseline after tests: registration across multiple devices, incoming parallel ringing to all target devices (especially Fanvil), outbound dialing, proper first-answer selection, BYE/CANCEL routing, audio in both directions, RTP resource sanity, reconnect after NAT rebinding, security scans rejected, and successful rollback in a separate environment.

Keep `v1.0.0` Git tag immutable. Any later changes go to a new branch/PR with a new release tag after acceptance.
