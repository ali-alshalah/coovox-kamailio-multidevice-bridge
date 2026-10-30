# Technical Reference — CooVox/Kamailio Multi-Device SIP Bridge

**Release:** v1.0.0 · 2026-10-30 · [Arabic operations](OPERATIONS_AR.md) · [Deployment](DEPLOYMENT.md)

## 1. Supported scope and topology

A ZYCOO CooVox PBX authenticates SIP users behind an OpenVPN tunnel. A public Ubuntu VPS hosts a dedicated Kamailio UDP edge proxy and an isolated RTPengine. SIP phones (Fanvil), softphones (MicroSIP), and CooCall on iPhone register to the VPS. This project adds **stateful tracking of several authenticated external contacts for the same numeric extension**, without moving password authentication from the PBX.

```text
SIP endpoints (UDP/15060)
     |
     v
VPS public address, ingress NAT REDIRECT :15060 → :17060
     |
     +--> Kamailio udp:PUBLIC_IP:17060 and udp:VPN_SERVER_IP:17060
     |       |-- registered contacts (SQLite-backed htable)
     |       |-- 5 numeric-extension slots, plus CooCall app_ variant
     |       |-- parallel SIP INVITE branches (public egress socket per branch)
     |       |-- registered-peer-only INVITE admission
     |       `-- media instructions → RTPengine 127.0.0.1:22231
     |
     +--> RTPengine public + VPN media interfaces, UDP 22000–23999
     |
     `--> OpenVPN tunnel → CooVox PBX :5060, ZYCOO authenticated registration
```

External registration is performed against `sip.example.com:15060` **in the example only**. Set your own address in `.env` and render `coovox.cfg` with `scripts/render_config.py`. Avoid committing production `.env` files.

## 2. Exact production-side components at the baseline

| Component | Runtime | Responsibility |
|---|---|---|
| Ubuntu | 24.04 LTS | Host OS |
| Kamailio | 5.7.4 | SIP routing/proxy and htable persistence |
| RTPengine | 11.5.1 | SDP/media relay; userspace mode |
| OpenVPN | 2.6.x | Encrypted transport to PBX |
| SQLite | 3.45.x | Persistent htable (`reg` and `regmulti`) |
| CooVox PBX | Varies with deployed firmware | User authentication; internal call routing; max registrations |

The public configuration is a **sanitized renderable copy**, not an image of a running machine. It references systemd, a local Kamailio unix RPC socket and an existing VPN interface. Deployment requires privileges and a separately configured VPN.

## 3. SIP listen sockets / NAT

- Public UDP 15060: exposed to remote SIP clients.
- Public UDP 17060: Kamailio bound socket (public-facing bridge). Ingress NAT `REDIRECT 15060→17060` takes priority over the old direct DNAT rule.
- Internal VPN UDP 17060: Kamailio ↔ PBX.
- Internal VPN UDP 17061 / 17062: rotating CooCall `app_100` contact sockets.
- PBX VPN UDP 5060: PBX SIP server.
- `127.0.0.1:22231`: Kamailio ↔ RTPengine NG control.
- RTPengine media UDP 22000–23999, distinct from local Asterisk's other RTP range.

Incoming packets to UDP/15060 must be redirected to Kamailio **before** a legacy direct-to-PBX DNAT fallback. Beware of altering iptables/nft chain order: the earlier rule wins. The network templates are for documenting existing legacy behavior; do not blindly execute both forwarding modes as independent production paths.

## 4. REGISTER and authentication

### A basic numeric extension REGISTER transaction

1. Endpoint sends `REGISTER` to `PUBLIC_HOST:15060`.
2. NAT maps it to public `:17060`; Kamailio applies a per-IP fixed 60-second window (`120` REGISTER requests in the baseline) and rejects usernames outside `100–199` or the `app_` equivalent.
3. Kamailio removes the device's original SIP `Contact` and substitutes a PBX-visible proxy contact (`VPN_SERVER_IP:17060`). It **does not** change Digest credentials.
4. Kamailio forwards `REGISTER` over VPN to `PBX_VPN_IP:5060`.
5. PBX may reply `401 Unauthorized` as a normal initial challenge; the endpoint retries with Digest `Authorization`. Only a PBX `200 OK` authorizes storing a client contact.
6. The public client source IP/UDP port is recorded in `reg`, and in one of `regmulti`'s five numeric-extension slots. For `app_100`, the app contact remains keyed separately in `reg`.

### State tables

| Table / key | Value | Notes |
|---|---|---|
| `reg`: `100` | `sip:CLIENT_PUBLIC_IP:UDP_PORT` | Latest accepted normal SIP registration; backward compatibility |
| `reg`: `app_100` | `sip:APP_PUBLIC_IP:UDP_PORT` | CooCall registration distinct from numeric extension |
| `regmulti`: `100#1` ... `100#5` | `sip:CLIENT_PUBLIC_IP:UDP_PORT` | Individually accepted devices |
| `regmulti`: `100#N#ts` | Unix timestamp | Last refresh after authenticated `200 OK` |
| `pending`: `Call-ID` | pre-auth IP/port | Short-lived; never used as proof before PBX `200` |
| `dialogpeer`: `Call-ID|To-tag` | selected transport peer | Keep in-dialog requests on answering device |
| `regipwindow` and `regiplimit` | first timestamp / count | Fixed-window REGISTER rate controls |

`regmulti` is configured for persistence through SQLite `coovox_multi_contacts`. The match window is 3600 seconds, with htable autoexpiry 7200 seconds. A new registration at the same IP:port refreshes its existing slot; an additional socket takes a free slot; when five are full, the oldest may be replaced. Changing any of these semantics should receive targeted tests.

**Unregister behavior:** a known registering device can remove its own slot while other slots remain. Avoid making a shared unregister from one client remove the sole PBX-side contact that all devices depend upon. The release includes a targeted local response for a known authenticated unregister with other live contacts; do not blindly port this logic to unrelated registrars. A cryptographically verified unregister is a more robust future enhancement.

## 5. Incoming call fan-out

The PBX sends `INVITE sip:100@VPN_SERVER_IP:17060` to Kamailio. In the new `PBX → external INVITE` path:

1. Check `regmulti` numeric slots 1...5 for the requested extension.
2. Append one branch per recently authenticated socket (guarding address syntax and timestamps).
3. Add `app_100` from `reg`, if present.
4. Route all public branches to the **same public Kamailio source socket** using the transaction branch callback:

```kamailio
t_on_branch("PUBLIC_FORK");

branch_route[PUBLIC_FORK] {
    set_send_socket("udp:PUBLIC_IP:17060");
}
```

`PUBLIC_IP` is explanatory pseudocode; the actual template uses `{{SIP_PUBLIC_IP}}`. This is the most important regression guard for Fanvil: an earlier revision sent secondary branches with `VPN_SERVER_IP` as source. MicroSIP was the primary branch and rang, while Fanvil missed its INVITE despite successful registration and OPTIONS replies.

The proxy collects provisional responses such as `180 Ringing` and selects the first successful `200 OK`. Other ringing branches are canceled as normal SIP forking behavior. When a PBX re-INVITE, BYE or ACK arrives, `dialogpeer` uses the accepted To-tag to address the specific answering socket instead of whichever device most recently refreshed registration.

**Note:** the PBX may also send a separate `app_100` INVITE using its rotated VPN socket. Distinguish that transaction from the numeric-extension fanout when reading packet captures.

## 6. Outbound calls and admission control

For a public-originated initial `INVITE`, Kamailio checks the caller's numeric extension (`From`) and verifies that the actual source IP **and UDP port** matches either an accepted `reg` socket or one of the fresh `regmulti` slots. An unknown socket receives `403` before RTPengine is asked to allocate media ports. This prevents unsolicited SIP scans from exhausting media resources.

This is **source-flow admission, not PBX-style password verification on every INVITE**; PBX still authenticates SIP. This design is susceptible to UDP NAT rebinding between registration and call setup until a successful re-register, and it relies on proper source/port matching. Do not loosen it to accept all INVITE requests merely because `From` contains `100`.

## 7. RTPengine / SDP / MTU

RTPengine has separate `internal` (VPN) and `external` (public) media interfaces and listens on `127.0.0.1:22231`. Kamailio uses `rtpengine_offer` for initial INVITEs and `rtpengine_manage` for media responses/in-dialog updates. The baseline media port range is `22000–23999`.

An earlier vulnerable routing rule allocated an RTPengine session for every unauthorized external INVITE. A sustained SIP scan consumed nearly every available RTP port (`Ran out of ports`). The current INVITE source/port guard is **before** RTP allocation; keep this ordering in any new release.

The deployed OpenVPN server uses `tun-coovox` and a service post-start `mtu 1280` hook to avoid lost large SIP INVITE datagrams observed in this topology. This value is empirical, not a universal network setting.

## 8. Persistence and restarts

- `reg` and `regmulti` are htable-backed, with SQLite tables `coovox_contacts` and `coovox_multi_contacts` respectively.
- The existing snapshot timer stores `reg` periodically; it does **not** necessarily flush `regmulti` every minute. The `scripts/backup.sh` example explicitly attempts to store both tables before backing up SQLite. A graceful Kamailio shutdown also stores dbmode=1 tables.
- A dirty crash could lose recent contacts; a fresh authenticated REGISTER restores them. Preserve PBX credentials out of the repository.
- Restarting Kamailio may briefly interrupt SIP setup and transaction state; restarting RTPengine can drop active audio. Always schedule and verify.

## 9. How to reproduce the stable configuration

`templates/kamailio/coovox.cfg.tpl` and `templates/rtpengine/coovox.conf.tpl` were produced by replacing production IPs/hostnames with placeholders. Rendering with the original values reproduced the stable file byte-for-byte at release time (see `VERSION.json` SHA-256 for the private production source file). The repository deliberately does not include those real values.

Use `scripts/render_config.py` and a local `.env` file. If you change templates, run syntax checking and live device tests. See [DEPLOYMENT.md](DEPLOYMENT.md) and [TESTING.md](TESTING.md).

## 10. Known risks and items out of scope

- The PBX may limit simultaneous registrations independently of Kamailio; verify this per extension.
- A `401` after Digest authentication indicates an account/credential challenge not fixed by this proxy. The historical example extension `151` remains an unresolved separate issue.
- CooVox call recording settings (`In & Out`) alone do not prove that audio files are being written. No successful recording verification is claimed.
- Do not publish real SIP addresses, IPs, PCAPs, hashes of passwords, DB records, OpenVPN private material or tokens.
- Direct UDP SIP exposed to the Internet attracts scans; keep firewall and rate protections under review.
- Test symmetric ringing/answering with each client and RTP audio both ways; a packet-level test does not replace end-user acceptance.
