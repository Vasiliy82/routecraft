#!/bin/sh
# Minimal one-arm IPv4 gateway for the RouteCraft test VM.
set -eu

interface=${ROUTECRAFT_LAN_INTERFACE:-}
subnet=${ROUTECRAFT_LAN_SUBNET:-}

# Input is configuration, not shell code: reject strings outside these forms.
case "$interface" in *[!a-zA-Z0-9_.-]*|'') echo 'Invalid LAN interface' >&2; exit 1;; esac
case "$subnet" in *[!0-9./]*|'') echo 'Invalid IPv4 subnet' >&2; exit 1;; esac
ip link show dev "$interface" >/dev/null

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.send_redirects=0 >/dev/null
sysctl -w "net.ipv4.conf.$interface.send_redirects=0" >/dev/null

# This table is owned exclusively by the PoC. Recreating it avoids duplicates.
if nft list table inet routecraft_poc >/dev/null 2>&1; then
    nft delete table inet routecraft_poc
fi
nft -f - <<EOF
table inet routecraft_poc {
    chain postrouting {
        type nat hook postrouting priority srcnat + 10; policy accept;
        iifname "$interface" oifname "$interface" ip saddr $subnet ip daddr != $subnet counter masquerade
    }
}
EOF
echo "RouteCraft PoC: IPv4 forwarding and SRCNAT enabled on $interface ($subnet)."
nft list table inet routecraft_poc
