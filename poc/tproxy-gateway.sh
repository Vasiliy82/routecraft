#!/bin/sh
# Attach the running PoC sing-box to transit IPv4 TCP/UDP on the LAN.
set -eu

ip route replace local default dev lo table 100
if ! ip rule show | grep -q 'fwmark 0x81 lookup 100'; then
    ip rule add fwmark 0x81 lookup 100
fi
if nft list table inet routecraft_tproxy >/dev/null 2>&1; then
    nft delete table inet routecraft_tproxy
fi
nft -f - <<'EOF'
table inet routecraft_tproxy {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        iifname != "br-lan" return
        ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return
        meta l4proto { tcp, udp } counter tproxy ip to 127.0.0.1:12345 meta mark set 0x81 accept
    }
}
EOF
echo 'RouteCraft PoC: transit IPv4 TCP/UDP is sent to sing-box.'
