# Known issues & limits — v1.0.0

The following are **not** claimed fixed by the stable multiple-device release.

1. **Extension 151 repeated SIP `401` after Digest.** The phone sent `REGISTER`, CooVox challenged and a second authenticated REGISTER also received `401`. This points to PBX/endpoint credential, realm or extension account behavior rather than broken UDP routing. Do not repeatedly change passwords in Kamailio; PBX authenticates.
2. **CooVox automatic audio recording.** An extension was configured as `Call Recording: In & Out` in the PBX web UI, but actual recording files remained unverified. This is a PBX recording/storage subsystem question, distinct from SIP signaling.
3. **CooCall APP notifications and stale contacts.** `app_100` uses special rotated UDP ports. In specific traces, SIP `NOTIFY`/`OPTIONS` attempts got `481` or `408`. These do not automatically imply a failed answered call; trace the full transaction and current NAT contact.
4. **Expired/stale SIP NAT contacts.** The reference `regmulti` entry has a last-seen time and requires re-registration. Sudden NAT mapping changes can invalidate an old socket before the expiration period. Follow endpoint registration traces.
5. **Simultaneous registrations have two separate limits.** CooVox may limit device count independently from Kamailio's five numeric extension slots. The reference user's PBX extension 100 was already set to allow 5 devices.
6. **Media must be tested separately.** SIP `180 Ringing` and `200 OK` are not proof of symmetric RTP. Test voice both directions and verify media port access and SDP translation.
7. **Public SIP is exposed to scanning.** Rate limiting, registered-socket admission, OS patching and firewalls are essential. Do not remove protections for troubleshooting without a bounded, approved plan.
8. **Registrations persistence on crash.** `regmulti` persists via SQLite on graceful shutdown; the legacy timer stores `reg` periodically. A violent host crash may lose newer `regmulti` slots until clients re-register. Consider adding a tested multi-table flush to a future release.
9. **No full VM/PBX backup in the public repo.** Full recovery additionally needs private VPN material, PBX settings, current DB, authorized firewall rules, host packages and secrets.

For further debugging, consult [OPERATIONS_AR.md](OPERATIONS_AR.md), [TECHNICAL_REFERENCE.md](TECHNICAL_REFERENCE.md) and [RESTORE.md](RESTORE.md).
