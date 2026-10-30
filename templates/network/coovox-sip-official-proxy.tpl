#!/bin/sh
# Route only public inbound SIP UDP/15060 into the existing Kamailio
# listener UDP/17060, with conntrack reversing replies to UDP/15060.
# Original DNAT rule remains behind this rule for instant rollback.
set -eu
IPT=/usr/sbin/iptables
case "${1:-}" in
 start)
   if ! "$IPT" -w 5 -t nat -C PREROUTING -i eth0 -d {{SIP_PUBLIC_IP}} -p udp --dport 15060 -m comment --comment coovox-official-sip-15060-proxy -j REDIRECT --to-ports 17060 2>/dev/null; then
     "$IPT" -w 5 -t nat -I PREROUTING 1 -i eth0 -d {{SIP_PUBLIC_IP}} -p udp --dport 15060 -m comment --comment coovox-official-sip-15060-proxy -j REDIRECT --to-ports 17060
   fi
   ;;
 stop)
   "$IPT" -w 5 -t nat -D PREROUTING -i eth0 -d {{SIP_PUBLIC_IP}} -p udp --dport 15060 -m comment --comment coovox-official-sip-15060-proxy -j REDIRECT --to-ports 17060 2>/dev/null || true
   ;;
 status)
   "$IPT" -w 5 -t nat -C PREROUTING -i eth0 -d {{SIP_PUBLIC_IP}} -p udp --dport 15060 -m comment --comment coovox-official-sip-15060-proxy -j REDIRECT --to-ports 17060
   ;;
 *) echo 'Usage: coovox-sip-official-proxy {start|stop|status}' >&2; exit 2;;
esac
