# Testing & acceptance matrix

## Release v1.0.0 test evidence — 2026-10-30

| Test | Observed baseline outcome | Scope |
|---|---|---|
| Two numeric SIP contacts authenticate under extension 100 | Passed in loopback stage | Separate htable slots after PBX 200 |
| Separate CooCall `app_100` contact | Passed in stage and observed live | App flow preserved |
| Concurrent inbound INVITE to 2 ordinary + app contact | Passed in stage | Three SIP branches |
| Branch `180 Ringing` and `200 OK` to PBX | Passed in stage | SIP signaling |
| BYE routed to answering device, not latest-registering device | Passed in stage | Dialog routing |
| Unregistered source INVITE rejected | Passed in stage | SIP guard |
| Known-device unregister preserves other contacts | Passed in stage | Registration state |
| Slot persistence across graceful stage restart | Passed | SQLite-backed htable |
| Wrong public/inside source reproduced then corrected | Passed in isolated test | Public branch socket |
| Real Fanvil outgoing call 100→112 | Confirmed by system operator | User test |
| Real inbound ringing 112→100 on MicroSIP, CooCall, Fanvil | Confirmed by system operator after fix | User test |
| Kamailio, RTPengine, OpenVPN active post-change | Passed | VPS health |
| End-to-end audio quality on all calls/networks | Not established by these tests | Manual test required |
| CooVox audio recording file generated and playable | Not established | Separate known issue |
| Extension 151 password/Digest failure resolved | No | Separate known issue |

## Repeat before every promotion

**Registration checks:** Two or more endpoints share the same numeric extension. Compare authenticated `REGISTER` + PBX `200 OK` for each. Confirm `regmulti` has distinct `ext#N` entries and refresh timestamps; ensure shared public-source rate limit does not cause `503`.

**Incoming call:** Dial extension from another extension. Check the INVITE is sent to *every* registered client and every branch has the **public** SIP source IP. Confirm each eligible handset rings. Answer on each handset in separate calls and check cancellation of losing branches.

**Outbound call:** Originate a call from each device. Ensure Kamailio allows registered source sockets and refuses unregistered spoofed sources. Verify PBX receives authenticated INVITE and the callee rings.

**Media:** Confirm audio in both directions with both G.711 A-law and μ-law where appropriate. Verify no RTPengine port exhaustion under ordinary load and that the PBX's direct RTP range does not overlap the proxy's media range.

**Stability:** Reconnect iPhone Wi-Fi/cellular, change external NAT mapping, reboot one handset, then check registrations reappear without causing other devices to vanish. Confirm SQLite state survives a graceful service restart in a staging environment.

**Rollback:** Restore a saved configuration in a staging environment and confirm the known-good baseline can be reactivated without corrupting registration tables. Never rely on a Git tag alone to restore production credentials/DB.

## Automated checks included

```bash
python3 -m unittest discover -s tests -v
python3 scripts/render_config.py --env .env.example --output /tmp/coovox-render-test
kamailio -c -f /tmp/coovox-render-test/coovox.cfg
```

The Python test suite checks template rendering, production-address redaction, and important routing feature markers. It **does not** launch a real PBX or simulate audio. For full integration tests, create a loopback-only Kamailio instance on separate ports with a mock SIP PBX and client agents, and never send synthetic test credentials to a live PBX.
