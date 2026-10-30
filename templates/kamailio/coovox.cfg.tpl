#!KAMAILIO
# CooVox stage SIP edge proxy. THIS FILE USES ONLY STAGING PORT 17060.
# Production port 15060 remains forwarded by the old NAT service.
debug=1
log_stderror=no
fork=yes
children=2
auto_aliases=no
dns=no
rev_dns=no
disable_tcp=yes
listen=udp:{{SIP_PUBLIC_IP}}:17060 advertise {{SIP_PUBLIC_HOST}}:17060
listen=udp:{{VPN_SERVER_IP}}:17060
listen=udp:{{VPN_SERVER_IP}}:17061
listen=udp:{{VPN_SERVER_IP}}:17062
alias={{SIP_PUBLIC_HOST}}:17060

loadmodule "tm.so"
loadmodule "corex.so"
loadmodule "sl.so"
loadmodule "rr.so"
loadmodule "maxfwd.so"
loadmodule "textops.so"
loadmodule "pv.so"
loadmodule "db_sqlite.so"
loadmodule "htable.so"
loadmodule "ctl.so"
loadmodule "rtpengine.so"
loadmodule "siputils.so"
loadmodule "sanity.so"
loadmodule "pike.so"
loadmodule "xlog.so"

modparam("rr", "enable_double_rr", 2)
# Store the contact only after PBX authenticates REGISTER with 200 OK.
# CooCall uses distinct app_100 contacts; these must not overwrite 100.
# Persist PBX-authenticated NAT contacts across a graceful restart.
# Expires timestamps are preserved; provisional REGISTER flows are not persisted.
modparam("htable", "db_url", "sqlite:///var/lib/coovox-sip/registered-contacts.sqlite")
modparam("htable", "db_expires", 1)
modparam("htable", "htable", "reg=>size=8;autoexpire=7200;dbtable=coovox_contacts;dbmode=1")
# Local-only status and read-only troubleshooting over Unix socket.
modparam("ctl", "binrpc", "unix:/var/lib/coovox-sip/kamailio_ctl")
modparam("htable", "htable", "pending=>size=8;autoexpire=120")
modparam("htable", "htable", "app100edge=>size=2;autoexpire=7200")
modparam("htable", "htable", "pending_edgeport=>size=8;autoexpire=120")
# Multi-registration slots for numeric extensions. Each key is ext#slot,
# with ext#slot#ts recording the last authenticated refresh time.
modparam("htable", "htable", "regmulti=>size=10;autoexpire=7200;dbtable=coovox_multi_contacts;dbmode=1")
modparam("htable", "htable", "dialogpeer=>size=10;autoexpire=14400")
modparam("htable", "htable", "pendingunreg=>size=8;autoexpire=120")
# SIP REGISTER abuse controls: real public source IP, not the PBX's VPN IP.
# Fast burst controls via pike and a generous 60-second per-IP quota.
modparam("pike", "sampling_time_unit", 10)
modparam("pike", "reqs_density_per_unit", 45)
modparam("pike", "remove_latency", 120)
modparam("htable", "htable", "regiplimit=>size=9;autoexpire=180")
modparam("htable", "htable", "regipwindow=>size=9;autoexpire=180")
modparam("rtpengine", "rtpengine_sock", "udp:127.0.0.1:22231")

request_route {
    if (!mf_process_maxfwd_header("10")) {
        sl_send_reply("483", "Too Many Hops");
        exit;
    }
    if (!sanity_check("1511", "7")) {
        exit;
    }
    force_rport();

    # Local-only test. Do not use production public port.
    if (is_method("OPTIONS") && ($si=="127.0.0.1" || $si=="{{SIP_PUBLIC_IP}}" || $si=="{{VPN_SERVER_IP}}")) {
        sl_send_reply("200", "Coovox Stage Proxy");
        exit;
    }

    # Transaction matching and in-dialog routing
    if (has_totag()) {
        if (loose_route()) {
            # PBX dialogues can carry the NAT client's private Contact
            # (e.g. 172.20.x.x). Always route PBX-originated in-dialog
            # requests toward the authenticated public REGISTER flow.
            if ($si=="{{PBX_VPN_IP}}" && ($rU =~ "^(app_)?[0-9]{2,5}$")) {
                if ($sht(reg=>$rU)==$null) {
                    sl_send_reply("481", "Remote Extension Not Registered");
                    exit;
                }
                # Dialog identifies the selected answering SIP contact; never
                # redirect an established call when another device refreshes.
                $var(dialog_key) = $ci + "|" + $tt;
                $var(nat_peer) = $sht(dialogpeer=>$var(dialog_key));
                if ($var(nat_peer)==$null) {
                    $var(nat_peer) = $sht(reg=>$rU);
                }
                if (!($var(nat_peer) =~ "^sip:[0-9.]+:[0-9]+$")) {
                    sl_send_reply("481", "Remote Extension Contact Invalid");
                    exit;
                }
                # Retain the SIP username when rewriting the NAT IP:port.
                # CooCall rejects username-less inbound R-URIs with 404.
                $var(remote_user) = $rU;
                $ru = "sip:" + $var(remote_user) + "@" + $(var(nat_peer){uri.host}) + ":" + $(var(nat_peer){uri.port});
                $du = $null;
                force_send_socket(udp:{{SIP_PUBLIC_IP}}:17060);
                xlog("L_INFO", "CooVox PBX dialog routed via registered NAT flow for ext=$rU\n");
            }
            if (is_method("BYE|CANCEL|ACK|INVITE|UPDATE")) {
                rtpengine_manage("replace-origin replace-session-connection");
            }
            if (!t_relay()) sl_reply_error();
            exit;
        }
        if (is_method("ACK") && t_check_trans()) {
            t_relay();
            exit;
        }
        sl_send_reply("404", "Dialog Not Found");
        exit;
    }

    if (is_method("CANCEL")) {
        if (t_check_trans()) t_relay();
        exit;
    }

    if ($si=="{{PBX_VPN_IP}}") {
        # Ring up to five independently PBX-authenticated sockets of an
        # ordinary extension; append its CooCall app_ variant when present.
        # Other PBX methods retain the established single-contact handling.
        if (is_method("INVITE") && $rU =~ "^1[0-9]{2}$") {
            $var(target_ext) = $rU;
            $var(branches) = 0;
            $var(i) = 1;
            while ($var(i) <= 5) {
                $var(slot_key) = $var(target_ext) + "#" + $var(i);
                $var(time_key) = $var(slot_key) + "#ts";
                $var(peer) = $sht(regmulti=>$var(slot_key));
                $var(seen) = $sht(regmulti=>$var(time_key));
                if ($var(peer) =~ "^sip:[0-9.]+:[0-9]+$"
                        && $var(seen)!=$null && ($Ts - $var(seen)) <= 3600) {
                    $var(target) = "sip:" + $var(target_ext) + "@" + $(var(peer){uri.host}) + ":" + $(var(peer){uri.port});
                    if ($var(branches)==0) {
                        $ru = $var(target);
                        $du = $null;
                    } else {
                        append_branch($var(target));
                    }
                    $var(branches) = $var(branches) + 1;
                }
                $var(i) = $var(i) + 1;
            }
            # Graceful migration: use the old authenticated contact when no
            # multi-device refresh has occurred yet after deployment.
            if ($var(branches)==0 && $sht(reg=>$var(target_ext)) =~ "^sip:[0-9.]+:[0-9]+$") {
                $var(peer) = $sht(reg=>$var(target_ext));
                $ru = "sip:" + $var(target_ext) + "@" + $(var(peer){uri.host}) + ":" + $(var(peer){uri.port});
                $du = $null;
                $var(branches) = 1;
            }
            $var(app_ext) = "app_" + $var(target_ext);
            $var(app_peer) = $sht(reg=>$var(app_ext));
            if ($var(app_peer) =~ "^sip:[0-9.]+:[0-9]+$") {
                $var(target) = "sip:" + $var(app_ext) + "@" + $(var(app_peer){uri.host}) + ":" + $(var(app_peer){uri.port});
                if ($var(branches)==0) {
                    $ru = $var(target);
                    $du = $null;
                } else {
                    append_branch($var(target));
                }
                $var(branches) = $var(branches) + 1;
            }
            if ($var(branches)==0) {
                sl_send_reply("480", "Extension Not Registered At Proxy");
                exit;
            }
            xlog("L_INFO", "CooVox multidest: ext=$var(target_ext) count=$var(branches)\n");
            force_send_socket(udp:{{SIP_PUBLIC_IP}}:17060);
            record_route();
            if (has_body("application/sdp")) {
                if (!rtpengine_offer("replace-origin replace-session-connection direction=internal direction=external ICE=remove")) {
                    sl_send_reply("488", "Media Proxy Not Available");
                    exit;
                }
            }
            t_on_reply("MEDIA");
            # Each fork is a distinct TM branch; parent force_send_socket()
            # only selects the primary branch. Without a branch callback,
            # secondary forks inherit the private VPN source ({{VPN_SERVER_IP}}).
            t_on_branch("PUBLIC_FORK");
            if (!t_relay()) sl_reply_error();
            exit;
        }
        # Incoming call from CooVox to an extension registered via this proxy.
        if (!($rU =~ "^(app_)?[0-9]{2,5}$")) {
            sl_send_reply("403", "Invalid Extension");
            exit;
        }
        # The PBX rings a numeric extension (e.g. 100), while ZYCOO
        # CooCall registers as app_100. Ring both authenticated NAT contacts
        # in parallel, and let Kamailio TM select the first 200 OK.
        # Never turn an unregistered or unvalidated contact into a branch.
        if (is_method("INVITE") && ($rU=="100" || $rU=="113")) {
            xlog("L_WARN", "COOVOX_FORK_DIAG phase=PBX_INVITE extension=$rU source=$si useragent=$hdr(User-Agent)\n");
        }
        $var(uri) = "no-contact";
        if ($sht(reg=>$rU)!=$null) {
            $var(uri) = $sht(reg=>$rU);
        }
        if (is_method("INVITE") && ($rU =~ "^[0-9]{2,5}$")) {
            $var(app_user) = "app_" + $rU;
            if ($rU=="100" || $rU=="113") {
                xlog("L_WARN", "COOVOX_FORK_DIAG phase=LOOKUP extension=$rU normal=$var(uri) app=$sht(reg=>$var(app_user))\n");
            }
            if ($sht(reg=>$var(app_user))!=$null) {
                $var(app_uri) = $sht(reg=>$var(app_user));
                if ($var(app_uri) =~ "^sip:[0-9.]+:[0-9]+$") {
                    if (($var(uri) =~ "^sip:[0-9.]+:[0-9]+$") && $var(uri)!=$var(app_uri)) {
                        # CooCall requires the app_ username in Request-URI.
                        $var(app_target) = "sip:" + $var(app_user) + "@" + $(var(app_uri){uri.host}) + ":" + $(var(app_uri){uri.port});
                        append_branch($var(app_target));
                        xlog("L_WARN", "COOVOX_FORK_DIAG phase=APPENDED extension=$rU app_uri=$var(app_target)\n");
                        xlog("L_INFO", "CooVox inbound fork: normal and CooCall app for ext=$rU\n");
                    } else if (!($var(uri) =~ "^sip:[0-9.]+:[0-9]+$")) {
                        $var(uri) = $var(app_uri);
                        xlog("L_INFO", "CooVox inbound: app-only registered for ext=$rU\n");
                    }
                }
            }
        }
        if (!($var(uri) =~ "^sip:[0-9.]+:[0-9]+$")) {
            sl_send_reply("480", "Extension Not Registered At Proxy");
            exit;
        }
        # The NAT binding is only a transport address. Preserve the intended
        # extension username so devices can match the incoming request.
        # For app-only registrations, route 113 as app_113 on the wire.
        $var(target_user) = $rU;
        if (is_method("INVITE") && ($rU =~ "^[0-9]{2,5}$") && $sht(reg=>$rU)==$null) {
            $var(target_user) = "app_" + $rU;
        }
        $ru = "sip:" + $var(target_user) + "@" + $(var(uri){uri.host}) + ":" + $(var(uri){uri.port});
        if (is_method("INVITE") && ($rU=="100" || $rU=="113")) {
            xlog("L_WARN", "COOVOX_FORK_DIAG phase=RELAY extension=$rU destination=$ru\n");
        }
        force_send_socket(udp:{{SIP_PUBLIC_IP}}:17060);
        if (is_method("INVITE")) {
            record_route();
            if (has_body("application/sdp")) {
                if (!rtpengine_offer("replace-origin replace-session-connection direction=internal direction=external ICE=remove")) {
                    sl_send_reply("488", "Media Proxy Not Available");
                    exit;
                }
            }
            t_on_reply("MEDIA");
        }
        if (!t_relay()) sl_reply_error();
        exit;
    }

    # From external endpoint. Support both standard extensions 100 and
    # ZYCOO CooCall app extensions app_100. CooVox remains the authenticator.
    # Forward only toward the CooVox PBX.
    if (is_method("REGISTER")) {
        # All ordinary devices share the PBX-facing Contact at 17060.
        # Do not let a fully authenticated, already known device removing
        # itself destroy the shared PBX binding of other active devices.
        # Unknown sockets and first (unauthed) requests still reach the PBX.
        if ($tU =~ "^1[0-9]{2}$" && $hdr(Authorization)!=$null
                && ($hdr(Expires)=="0" || $hdr(Contact)=~"expires=0")) {
            $var(unreg_peer) = "sip:" + $si + ":" + $sp;
            $var(remove_slot) = 0;
            $var(other_peer) = $null;
            $var(local_unreg) = 0;
            sht_lock("regmulti=>$tU");
            $var(i) = 1;
            while ($var(i)<=5) {
                $var(slot_key) = $tU + "#" + $var(i);
                $var(time_key) = $var(slot_key) + "#ts";
                $var(p) = $sht(regmulti=>$var(slot_key));
                $var(seen) = $sht(regmulti=>$var(time_key));
                if ($var(seen)!=$null && ($Ts - $var(seen))<=3600) {
                    if ($var(p) eq $var(unreg_peer)) {
                        $var(remove_slot) = $var(i);
                    } else if ($var(p) =~ "^sip:[0-9.]+:[0-9]+$") {
                        $var(other_peer) = $var(p);
                    }
                }
                $var(i) = $var(i) + 1;
            }
            if ($var(remove_slot)>0 && $var(other_peer)!=$null) {
                $var(slot_key) = $tU + "#" + $var(remove_slot);
                $var(time_key) = $var(slot_key) + "#ts";
                $sht(regmulti=>$var(slot_key)) = $null;
                $sht(regmulti=>$var(time_key)) = $null;
                if ($sht(reg=>$tU) eq $var(unreg_peer)) {
                    $sht(reg=>$tU) = $var(other_peer);
                }
                $var(local_unreg) = 1;
            }
            sht_unlock("regmulti=>$tU");
            if ($var(local_unreg)==1) {
                xlog("L_INFO", "CooVox multi: device unregistered locally while others remain ext=$tU\n");
                sl_send_reply("200", "OK");
                exit;
            }
        }
        # External source IP is preserved at the public SIP listener.
        # Keep quotas well above legitimate phones sharing one CGNAT IP.
        # Do not touch PBX-originated dialogs or other SIP methods.
        if ($si!="127.0.0.1" && $si!="{{SIP_PUBLIC_IP}}" && $si!="{{VPN_SERVER_IP}}") {
            # Pike is a supplementary signal, not a hard block for REGISTER.
            # Shared carrier NATs can place many legitimate extensions behind one IP.
            # The per-IP 60-second quota below remains enforced.
            if (!pike_check_req()) {
                xlog("L_WARN", "CooVox REGISTER pike threshold src=$si user=$tU\n");
            }
            # Fixed 60-second window. Incrementing an autoexpiring htable item
            # refreshes its expiry, so a plain counter can otherwise grow forever.
            if ($sht(regipwindow=>$si)==$null || ($Ts - $sht(regipwindow=>$si)) >= 60) {
                $sht(regipwindow=>$si) = $Ts;
                $sht(regiplimit=>$si) = 0;
            }
            $sht(regiplimit=>$si) = $sht(regiplimit=>$si) + 1;
            if ($sht(regiplimit=>$si)>120) {
                append_to_reply("Retry-After: 60\r\n");
                sl_send_reply("503", "REGISTER Rate Limited");
                exit;
            }
        }
        # CooVox has the 100-199 extension plan; allow numeric and app_ forms.
        # Reject SIP username probes outside it BEFORE forwarding to the PBX.
        if (!($tU =~ "^(app_)?1[0-9]{2}$")) {
            sl_send_reply("403", "Invalid Extension");
            exit;
        }
        # Do not authenticate here. Only PBX may accept credentials.
        # Store NAT destination only after its 200 OK is received.
        # Do not trust the registering source yet. Correlate its IP:port
        # to the subsequent PBX 200 OK using the SIP Call-ID (available
        # in both request and response routes, unlike transient AVPs).
        $sht(pending=>$ci) = "sip:" + $si + ":" + $sp;
        if ($hdr(Expires)=="0" || $hdr(Contact)=~"expires=0") {
            $sht(pendingunreg=>$ci) = 1;
        }
        # Keep authentication intact, replace Contact the PBX stores.
        # This ensures inbound INVITEs return through the VPN and proxy.
        remove_hf("Contact");
        if ($tU=="app_100") {
            # ZYCOO rewrites Contact to the UDP source socket.
            # Rotate VPN-only sockets only when the registered iOS NAT peer changes.
            # Commit the selected socket only after PBX accepts authentication.
            $var(app100_peer) = "sip:" + $si + ":" + $sp;
            $var(app100_port) = $sht(app100edge=>port);
            if ($sht(reg=>app_100)!=$var(app100_peer)) {
                if ($var(app100_port)=="17061") {
                    $var(app100_port)="17062";
                } else {
                    $var(app100_port)="17061";
                }
            }
            if ($var(app100_port)!="17061" && $var(app100_port)!="17062") {
                $var(app100_port)="17061";
            }
            if ($var(app100_port)=="17061") {
                append_hf("Contact: <sip:app_100@{{VPN_SERVER_IP}}:17061;transport=udp>\r\n");
                force_send_socket(udp:{{VPN_SERVER_IP}}:17061);
            } else {
                append_hf("Contact: <sip:app_100@{{VPN_SERVER_IP}}:17062;transport=udp>\r\n");
                force_send_socket(udp:{{VPN_SERVER_IP}}:17062);
            }
            $sht(pending_edgeport=>$ci) = $var(app100_port);
        } else {
            append_hf("Contact: <sip:$tU@{{VPN_SERVER_IP}}:17060;transport=udp>\r\n");
            force_send_socket(udp:{{VPN_SERVER_IP}}:17060);
        }
        $du = "sip:{{PBX_VPN_IP}}:5060";
        t_on_reply("REGISTRATION");
        if (!t_relay()) sl_reply_error();
        exit;
    }

    # Public call admission: only a PBX-authenticated registered SIP socket
    # is allowed to originate INVITE into CooVox. SIP scans previously
    # allocated RTPengine sessions before PBX could reject them with 401.
    # Keep PBX-originated calls ({{PBX_VPN_IP}}) on their separate route above.
    if (is_method("INVITE")) {
        $var(registered_socket) = "sip:" + $si + ":" + $sp;
        $var(allowed) = 0;
        if ($fU =~ "^(app_)?1[0-9]{2}$" && $sht(reg=>$fU) eq $var(registered_socket)) {
            $var(allowed) = 1;
        }
        if ($var(allowed)==0 && $fU =~ "^1[0-9]{2}$") {
            $var(i) = 1;
            while ($var(i) <= 5) {
                $var(slot_key) = $fU + "#" + $var(i);
                $var(time_key) = $var(slot_key) + "#ts";
                $var(peer) = $sht(regmulti=>$var(slot_key));
                $var(seen) = $sht(regmulti=>$var(time_key));
                if ($var(peer) eq $var(registered_socket)
                        && $var(seen)!=$null && ($Ts - $var(seen)) <= 3600) {
                    $var(allowed) = 1;
                }
                $var(i) = $var(i) + 1;
            }
        }
        if ($var(allowed)==0) {
            xlog("L_WARN", "CooVox SIP guard: denied unregistered INVITE from $si:$sp user=$fU\n");
            sl_send_reply("403", "Forbidden");
            exit;
        }
        # Tie the call to this exact registered contact for PBX re-INVITEs,
        # ACK and BYE even if another device changes the latest registration.
        $var(dialog_key) = $ci + "|" + $ft;
        $sht(dialogpeer=>$var(dialog_key)) = $var(registered_socket);
    }

    if (is_method("INVITE") && $si!="{{PBX_VPN_IP}}"
            && ($fU=="app_100" || $fU=="151" || $fU=="112")) {
        # Keep the existing app_100 PMTU fix. Extend the same safe header
        # compaction to extension 151 <-> 112 INVITEs only.
        # Preserve SIP authorization, Via, Contact, routing and SDP.
        remove_hf("Allow");
        remove_hf("Allow-Events");
        remove_hf("User-Agent");
        remove_hf("Supported");
        remove_hf("Accept");
        xlog("L_INFO", "CooVox PMTU: compacted optional outbound INVITE headers ext=$fU target=$rU\n");
    }

    if (is_method("INVITE|OPTIONS|MESSAGE|SUBSCRIBE|NOTIFY")) {
        # Never operate as an open SIP relay.
        $du = "sip:{{PBX_VPN_IP}}:5060";
        force_send_socket(udp:{{VPN_SERVER_IP}}:17060);
        if (is_method("INVITE")) {
            record_route();
            if (has_body("application/sdp")) {
                if (!rtpengine_offer("replace-origin replace-session-connection direction=external direction=internal ICE=remove")) {
                    sl_send_reply("488", "Media Proxy Not Available");
                    exit;
                }
            }
            t_on_reply("MEDIA");
        }
        if (!t_relay()) sl_reply_error();
        exit;
    }

    sl_send_reply("405", "Method Not Allowed");
    exit;
}

onreply_route[REGISTRATION] {
    if (t_check_status("200") && ($tU =~ "^(app_)?1[0-9]{2}$") && $sht(pending=>$ci)!=$null) {
        $var(registered_socket) = $sht(pending=>$ci);
        $var(unregister) = $sht(pendingunreg=>$ci);
        if ($tU =~ "^1[0-9]{2}$") {
            # Atomic slot selection for concurrent REGISTER 200 responses.
            sht_lock("regmulti=>$tU");
            $var(matchslot) = 0;
            $var(emptyslot) = 0;
            $var(oldestslot) = 1;
            $var(oldestseen) = $Ts;
            $var(i) = 1;
            while ($var(i) <= 5) {
                $var(slot_key) = $tU + "#" + $var(i);
                $var(time_key) = $var(slot_key) + "#ts";
                $var(peer) = $sht(regmulti=>$var(slot_key));
                $var(seen) = $sht(regmulti=>$var(time_key));
                if ($var(peer) eq $var(registered_socket)) {
                    $var(matchslot) = $var(i);
                } else if (($var(peer)==$null || $var(seen)==$null || ($Ts - $var(seen))>3600)
                           && $var(emptyslot)==0) {
                    $var(emptyslot) = $var(i);
                }
                if ($var(seen)==$null || $var(seen)<$var(oldestseen)) {
                    $var(oldestslot) = $var(i);
                    if ($var(seen)==$null) {
                        $var(oldestseen) = 0;
                    } else {
                        $var(oldestseen) = $var(seen);
                    }
                }
                $var(i) = $var(i) + 1;
            }
            if ($var(unregister)==1) {
                # Only remove the exact registration that authenticated.
                if ($var(matchslot)>0) {
                    $var(slot_key) = $tU + "#" + $var(matchslot);
                    $var(time_key) = $var(slot_key) + "#ts";
                    $sht(regmulti=>$var(slot_key)) = $null;
                    $sht(regmulti=>$var(time_key)) = $null;
                }
            } else {
                if ($var(matchslot)>0) {
                    $var(chosenslot) = $var(matchslot);
                } else if ($var(emptyslot)>0) {
                    $var(chosenslot) = $var(emptyslot);
                } else {
                    $var(chosenslot) = $var(oldestslot);
                }
                $var(slot_key) = $tU + "#" + $var(chosenslot);
                $var(time_key) = $var(slot_key) + "#ts";
                $sht(regmulti=>$var(slot_key)) = $var(registered_socket);
                $sht(regmulti=>$var(time_key)) = $Ts;
                xlog("L_INFO", "CooVox multi register ext=$tU slot=$var(chosenslot) peer=$var(registered_socket)\n");
            }
            sht_unlock("regmulti=>$tU");
        }
        if ($var(unregister)==1) {
            if ($sht(reg=>$tU) eq $var(registered_socket)) {
                $sht(reg=>$tU) = $null;
            }
        } else {
            $sht(reg=>$tU) = $var(registered_socket);
            if ($tU=="app_100" && $sht(pending_edgeport=>$ci)!=$null) {
                $sht(app100edge=>port) = $sht(pending_edgeport=>$ci);
                xlog("L_INFO", "CooVox app_100 registered via VPN source UDP $sht(app100edge=>port)\n");
            }
            xlog("L_INFO", "CooVox proxy: PBX-authenticated registration saved for extension $tU\n");
        }
        $sht(pending=>$ci) = $null;
        $sht(pendingunreg=>$ci) = $null;
        $sht(pending_edgeport=>$ci) = $null;
    }
}

onreply_route[MEDIA] {
    # The winning 200 response from one forked endpoint selects the dialog.
    if (t_check_status("200") && $si!="{{PBX_VPN_IP}}" && $tt!=$null) {
        $var(dialog_key) = $ci + "|" + $tt;
        $sht(dialogpeer=>$var(dialog_key)) = "sip:" + $si + ":" + $sp;
    }
    if (has_body("application/sdp")) {
        if (!rtpengine_manage("replace-origin replace-session-connection ICE=remove")) {
            xlog("L_ERR", "CooVox stage: unable to process SDP response\n");
        }
    }
}

# PBX -> internet: force *every* parallel fork onto the public listener,
# including Fanvil and any CooCall branch appended after the first.
branch_route[PUBLIC_FORK] {
    set_send_socket("udp:{{SIP_PUBLIC_IP}}:17060");
}
