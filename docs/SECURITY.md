# Security Guide & Disclosure

The repository is **public, sanitized documentation and deployment templates**, not a copy of a production PBX or VPS. Unauthorized SIP requests are routinely sent to any public SIP port. Do not expose credentials, telephony usage logs or endpoint information.

## Secrets that MUST NOT enter Git

- SIP account passwords, PINs, admin logins, tokens, session cookies or authorization headers.
- VPN private keys, CA private keys, TLS static keys, client profiles, `.ovpn`, certificate bundles.
- Production `.env`, PBX backup archives, CooVox firmware backups with private settings, SSH keys.
- SIP/PCAP captures, registration SQLite files, logs exposing customer telephone numbers, IPs or message contents.
- Real SIP hostnames/IPs of a specific environment unless the operator has intentionally approved their disclosure.

`.gitignore` excludes the most common file patterns, but that is **not a guarantee**. Review every staged file before committing. Public templates replace production addresses with `{{SIP_PUBLIC_IP}}`, `{{SIP_PUBLIC_HOST}}`, `{{VPN_SERVER_IP}}`, `{{PBX_VPN_IP}}`.

## Threat model / core controls

1. `REGISTER`: username limited to the configured extension plan, rate limit per public source IP (120 per 60 seconds in this baseline), with a fixed window. Kamailio does **not** authorize a contact until the PBX returns `200 OK`.
2. `INVITE`: check actual source UDP IP/port against accepted `reg` or fresh `regmulti` records before creating RTPengine media allocations. Do not trust `From` text alone.
3. Parallel ringing: use the **public** send socket for each TM branch; do not expose private tunnel routing or accidentally send externally with the VPN source address.
4. `regmulti`: preserve up to five independently accepted numeric contacts, with bounded freshness and SQLite persistence. Review the security assumptions of all user-supplied headers.
5. RTPengine: keep its NG control port bound to loopback only; restrict public media ports to the intended firewall range; do not offer it directly to public users.
6. OpenVPN: distribute trust material separately; do not push it into Git or external issue trackers.
7. Host: patch Ubuntu and services thoughtfully, preserve rollback, restrict root access and evaluate firewall changes with out-of-band access.

**Caveat:** an authenticated source IP/port can change under NAT. In the reference architecture, SIP endpoint registration binds a transport flow; clients must re-register when that flow changes. `REGISTER Expires: 0` on a known flow is handled to preserve other devices, but this local mechanism should be reviewed for stricter authentication guarantees before generalizing the deployment to hostile networks.

## Scanner and resource exhaustion history

An earlier revision forwarded untrusted INVITE requests toward the PBX and allocated RTP sessions before rejection. This exhausted UDP media ports (`Ran out of ports`). The stable release rejects an unregistered INVITE before `rtpengine_offer`, while preserving valid REGISTER and call paths. Retain this ordering.

## Privacy and PCAP handling

For diagnosis, prefer filtered packet captures of short duration, minimal snap length, and private file permissions. `Authorization: Digest` contains sensitive authentication material even though the password itself is not shown. Never post raw packet captures publicly; redact sensitive fields and real client IPs before sharing excerpts.

## Reporting vulnerabilities

Do **not** create a public issue with exploits against a live PBX, real secrets or active endpoint data. Contact the repository maintainer privately through GitHub profile channels or GitHub private vulnerability reporting where enabled. Include a minimal sanitized reproduction and the release number. Do not publish secrets for troubleshooting.

## Operational approval

Installing or changing a firewall rule, root-owned config, running service, VPN identity or public interface may break calls or connectivity. Obtain explicit operational approval, back up state, validate, deploy in a maintenance window and preserve a tested rollback. Configuration examples are not instructions to bypass organizational access controls.
