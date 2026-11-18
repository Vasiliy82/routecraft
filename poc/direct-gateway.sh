#!/bin/sh
# Prepare the existing IPv4 gateway for the RouteCraft PoC.
set -eu

interface=${ROUTECRAFT_LAN_INTERFACE:-}
wan_interface=${ROUTECRAFT_WAN_INTERFACE:-$interface}
subnet=${ROUTECRAFT_LAN_SUBNET:-}

# Input is configuration, not shell code: reject strings outside these forms.
case "$interface" in *[!a-zA-Z0-9_.-]*|'') echo 'Invalid LAN interface' >&2; exit 1;; esac
case "$wan_interface" in *[!a-zA-Z0-9_.-]*|'') echo 'Invalid WAN interface' >&2; exit 1;; esac
case "$subnet" in *[!0-9./]*|'') echo 'Invalid IPv4 subnet' >&2; exit 1;; esac
ip link show dev "$interface" >/dev/null
ip link show dev "$wan_interface" >/dev/null

if [ "$interface" != "$wan_interface" ]; then
    # A configured router already owns its forwarding and NAT rules. Never
    # replace them or add one-arm masquerading in this topology.
    [ "$(sysctl -n net.ipv4.ip_forward)" = 1 ] || { echo 'IPv4 forwarding is not enabled on this router.' >&2; exit 1; }
    if nft list table inet routecraft_poc >/dev/null 2>&1; then
        echo 'Existing one-arm NAT table requires an explicit migration before switching topology.' >&2
        exit 1
    fi
    echo "RouteCraft PoC: using existing IPv4 forwarding and firewall for $interface -> $wan_interface."
    exit 0
fi

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.send_redirects=0 >/dev/null
sysctl -w "net.ipv4.conf.$interface.send_redirects=0" >/dev/null

# Replace the owned table in one nft transaction; a failed replacement leaves
# the prior NAT table in place instead of removing it before validation.
replace_table=
if nft list table inet routecraft_poc >/dev/null 2>&1; then
    replace_table='delete table inet routecraft_poc'
fi
nft -f - <<EOF
$replace_table
table inet routecraft_poc {
    chain postrouting {
        type nat hook postrouting priority srcnat + 10; policy accept;
        iifname "$interface" oifname "$interface" ip saddr $subnet ip daddr != $subnet counter masquerade
    }
}
EOF
echo "RouteCraft PoC: IPv4 forwarding and SRCNAT enabled on $interface ($subnet)."
nft list table inet routecraft_poc
