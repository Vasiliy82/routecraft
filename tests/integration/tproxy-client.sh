#!/bin/sh
# Temporary host route affects only this destination and is removed on exit.
set -eu
target=1.1.1.1/32
gateway=192.168.80.241
if ip route show exact "$target" | grep -q .; then
    echo "A host route for $target already exists; refusing to replace it" >&2
    exit 1
fi
if ip -4 addr show dev br-lan | grep -q '198.18.0.2/'; then
    echo 'Test source address is already assigned; refusing to change it' >&2
    exit 1
fi
ip route add "$target" via "$gateway" dev br-lan
alias_added=0
cleanup() {
    [ "$alias_added" = 0 ] || ip addr del 198.18.0.2/32 dev br-lan 2>/dev/null || true
    ip route del "$target" via "$gateway" dev br-lan 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
ip addr add 198.18.0.2/32 dev br-lan
alias_added=1
echo 'CLIENT ROUTE:'
ip route get 1.1.1.1
echo 'HTTP RESPONSE:'
curl -sS -I --connect-timeout 5 --max-time 10 --noproxy '*' http://1.1.1.1/
echo 'HTTP RESPONSE FROM SECOND TEST SOURCE:'
curl -sS -I --interface 198.18.0.2 --connect-timeout 5 --max-time 10 --noproxy '*' http://1.1.1.1/
echo 'UDP DNS RESPONSE:'
nslookup -timeout=4 openwrt.org 1.1.1.1
