#!/bin/sh
# Dedicated SIP forwarding (CooVox project only).
# External UDP/15060 -> CooVox OpenVPN UDP/5060.
set -eu
IPT=/usr/sbin/iptables
COMMENT=coovox-sip-15060
case "${1:-}" in
 start)
   if ! "$IPT" -w 5 -t nat -C PREROUTING -i eth0 -d {{SIP_PUBLIC_IP}} -p udp --dport 15060 -m comment --comment "$COMMENT" -j DNAT --to-destination {{PBX_VPN_IP}}:5060 2>/dev/null; then
     "$IPT" -w 5 -t nat -A PREROUTING -i eth0 -d {{SIP_PUBLIC_IP}} -p udp --dport 15060 -m comment --comment "$COMMENT" -j DNAT --to-destination {{PBX_VPN_IP}}:5060
   fi
   if ! "$IPT" -w 5 -t nat -C POSTROUTING -o tun-coovox -d {{PBX_VPN_IP}} -p udp --dport 5060 -m conntrack --ctorigdst {{SIP_PUBLIC_IP}} --ctorigdstport 15060 -m comment --comment "$COMMENT" -j SNAT --to-source {{VPN_SERVER_IP}} 2>/dev/null; then
     "$IPT" -w 5 -t nat -A POSTROUTING -o tun-coovox -d {{PBX_VPN_IP}} -p udp --dport 5060 -m conntrack --ctorigdst {{SIP_PUBLIC_IP}} --ctorigdstport 15060 -m comment --comment "$COMMENT" -j SNAT --to-source {{VPN_SERVER_IP}}
   fi
   ;;
 stop)
   "$IPT" -w 5 -t nat -D PREROUTING -i eth0 -d {{SIP_PUBLIC_IP}} -p udp --dport 15060 -m comment --comment "$COMMENT" -j DNAT --to-destination {{PBX_VPN_IP}}:5060 2>/dev/null || true
   "$IPT" -w 5 -t nat -D POSTROUTING -o tun-coovox -d {{PBX_VPN_IP}} -p udp --dport 5060 -m conntrack --ctorigdst {{SIP_PUBLIC_IP}} --ctorigdstport 15060 -m comment --comment "$COMMENT" -j SNAT --to-source {{VPN_SERVER_IP}} 2>/dev/null || true
   ;;
 *) echo "Usage: $0 start|stop" >&2; exit 2;;
esac
