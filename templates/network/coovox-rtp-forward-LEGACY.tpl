#!/bin/sh
# CooVox dedicated RTP range on public VPS -> CooVox VPN tunnel.
# NEVER forwards 10000-10199: reserved by local Fanvil/Asterisk.
set -eu
IPT=/usr/sbin/iptables
TAG=coovox-rtp-20000-21000
case "${1:-}" in
start)
 if ! "$IPT" -w 5 -t nat -C PREROUTING -i eth0 -d {{SIP_PUBLIC_IP}} -p udp --dport 20000:21000 -m comment --comment "$TAG" -j DNAT --to-destination {{PBX_VPN_IP}} 2>/dev/null; then
  "$IPT" -w 5 -t nat -A PREROUTING -i eth0 -d {{SIP_PUBLIC_IP}} -p udp --dport 20000:21000 -m comment --comment "$TAG" -j DNAT --to-destination {{PBX_VPN_IP}}
 fi
 if ! "$IPT" -w 5 -t nat -C POSTROUTING -o tun-coovox -d {{PBX_VPN_IP}} -p udp --dport 20000:21000 -m conntrack --ctorigdst {{SIP_PUBLIC_IP}} --ctorigdstport 20000:21000 -m comment --comment "$TAG" -j SNAT --to-source {{VPN_SERVER_IP}} 2>/dev/null; then
  "$IPT" -w 5 -t nat -A POSTROUTING -o tun-coovox -d {{PBX_VPN_IP}} -p udp --dport 20000:21000 -m conntrack --ctorigdst {{SIP_PUBLIC_IP}} --ctorigdstport 20000:21000 -m comment --comment "$TAG" -j SNAT --to-source {{VPN_SERVER_IP}}
 fi
 ;;
stop)
 "$IPT" -w 5 -t nat -D PREROUTING -i eth0 -d {{SIP_PUBLIC_IP}} -p udp --dport 20000:21000 -m comment --comment "$TAG" -j DNAT --to-destination {{PBX_VPN_IP}} 2>/dev/null || true
 "$IPT" -w 5 -t nat -D POSTROUTING -o tun-coovox -d {{PBX_VPN_IP}} -p udp --dport 20000:21000 -m conntrack --ctorigdst {{SIP_PUBLIC_IP}} --ctorigdstport 20000:21000 -m comment --comment "$TAG" -j SNAT --to-source {{VPN_SERVER_IP}} 2>/dev/null || true
 ;;
*) echo "Usage: $0 start|stop" >&2; exit 2;;
esac
