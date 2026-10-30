# Changelog

## v1.0.0 — 2026-10-30 — Confirmed stable baseline

- Retained distinct public UDP SIP sockets for up to five authenticated numeric-extension contacts (`regmulti` table).
- Added persistent contact slots plus refresh timestamps and protected same-account unregister handling.
- Kept ZYCOO CooCall `app_100` contact separate from standard SIP `100`.
- Implemented parallel INVITE forking and branch-level public send-socket selection (`branch_route[PUBLIC_FORK]`).
- Bound in-dialog requests to the answering peer to avoid switching devices mid-call.
- Continued REGISTER 120-per-60-second fixed-window limiter and suspicious INVITE filtering.
- Confirmed registered clients can originate calls and unregistered clients cannot.
- Confirmed a real 112→100 call rings MicroSIP, iPhone CooCall and Fanvil after public source-socket fix.
- Preserved RTPengine/OpenVPN and existing NAT rollback path.
- Created safe public templates and operational runbooks; production credentials/DB excluded.

### Known limitations

- Public repository is a sanitized and parameterized configuration template, not a complete production VM image.
- Password authentication is performed by the PBX; recurring `401` for extension 151 was not solved by this release.
- Automatic call-audio recording was not verified as fixed by this release.
- Source-IP + UDP-port registration binding can change with NAT rebinding; refresh registration to recover.
