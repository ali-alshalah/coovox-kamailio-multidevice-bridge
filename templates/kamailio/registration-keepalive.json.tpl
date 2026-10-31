{
  "extensions": ["100"],
  "sip_domain": "{{SIP_PUBLIC_HOST}}",
  "send_socket": "udp:{{SIP_PUBLIC_IP}}:17060",
  "rpc_socket": "unix:/var/lib/coovox-sip/kamailio_ctl",
  "max_registration_age_seconds": 3600,
  "max_targets": 5
}
