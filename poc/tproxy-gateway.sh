#!/bin/sh
# Attach the running PoC sing-box to transit IPv4 TCP/UDP on the LAN.
set -eu

interface=${ROUTECRAFT_LAN_INTERFACE:-}
case "$interface" in *[!a-zA-Z0-9_.-]*|'') echo 'Invalid LAN interface' >&2; exit 1;; esac
ip link show dev "$interface" >/dev/null

ip route replace local default dev lo table 100
# Source validation performs a reverse lookup as local output (iif lo). If
# src_valid_mark is enabled, an unscoped mark rule sends the client's source
# to the local-default route as well, causing the kernel to drop the packet.
# Restrict this rule to real LAN ingress; reverse lookups then use main.
if ! ip rule show | grep -Fq "fwmark 0x81 iif $interface lookup 100"; then
    ip rule add fwmark 0x81 iif "$interface" lookup 100
fi
replace_table=
if nft list table inet routecraft_tproxy >/dev/null 2>&1; then
    replace_table='delete table inet routecraft_tproxy'
fi
# Submit deletion and creation as one nftables transaction so a restart does
# not briefly expose the forwarding path or discard the old table on failure.
nft -f - <<EOF
$replace_table
table inet routecraft_tproxy {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        iifname != "$interface" return
        ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return
        meta l4proto { tcp, udp } counter tproxy ip to 127.0.0.1:12345 meta mark set 0x81 accept
        # A missing transparent socket makes tproxy skip the previous rule.
        # Do not let that failure silently bypass the configured VPN policy.
        meta nfproto ipv4 meta l4proto { tcp, udp } counter drop
    }
}
EOF
echo 'RouteCraft PoC: transit IPv4 TCP/UDP is sent to sing-box.'
