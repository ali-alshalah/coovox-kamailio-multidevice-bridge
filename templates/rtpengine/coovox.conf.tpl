[rtpengine]
# Isolated CooVox media proxy, userspace-only (no kernel or iptables manipulation).
table = -1
interface = internal/{{VPN_SERVER_IP}};external/{{SIP_PUBLIC_IP}}
listen-ng = 127.0.0.1:22231
port-min = 22000
port-max = 23999
timeout = 60
silent-timeout = 180
num-threads = 2
log-level = 5
log-stderr = true
