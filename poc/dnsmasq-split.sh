#!/bin/sh
# Called under the activation lock, with a snapshot of DHCP and the ownership file.
set -efu
umask 077

mode=$1
state=$2
forwarder='127.0.0.1#10553'

fail() {
    echo "ERROR: Split DNS: $*" >&2
    exit 1
}

[ "$mode" = on ] || [ "$mode" = off ] || fail 'unknown DNS mode'
[ "$mode" = on ] || [ -f "$state" ] || exit 0

sections=$(uci -q show dhcp | sed -n 's/^\(dhcp\.[^=]*\)=dnsmasq$/\1/p')
set -- $sections
[ "$#" -eq 1 ] || fail 'exactly one dnsmasq instance is required'
section=$1
servers=$(uci -q get "$section.server" || true)
old_noresolv=$(uci -q get "$section.noresolv" || true)
old_cache=$(uci -q get "$section.cachesize" || true)

managed=0
for server in $servers; do
    case "$server" in
        "$forwarder") managed=$((managed + 1)) ;;
        '/#/'*|'//'*) [ "$mode" = off ] || fail 'existing catch-all DNS forwarding would bypass policy' ;;
        /*) : ;; # Keep explicitly configured local and private zones.
        *) [ "$mode" = off ] || fail 'existing default DNS forwarding would bypass policy' ;;
    esac
done

if [ -f "$state" ]; then
    [ "$managed" -eq 1 ] && [ "$old_noresolv" = 1 ] && [ "$old_cache" = 0 ] || fail 'managed dnsmasq options were edited'
    previous_section=$(sed -n '1p' "$state")
    [ "$previous_section" = "$section" ] || fail 'dnsmasq section changed since activation'
    [ "$mode" = off ] || exit 0
    previous_noresolv=$(sed -n '2p' "$state")
    previous_cache=$(sed -n '3p' "$state")
    uci del_list "$section.server=$forwarder"
    if [ -n "$previous_noresolv" ]; then uci set "$section.noresolv=$previous_noresolv"; else uci delete "$section.noresolv"; fi
    if [ -n "$previous_cache" ]; then uci set "$section.cachesize=$previous_cache"; else uci delete "$section.cachesize"; fi
    uci commit dhcp
    /etc/init.d/dnsmasq restart
    rm -f "$state"
else
    [ "$managed" -eq 0 ] || fail 'loopback DNS forwarder is already configured outside RouteCraft'
    printf '%s\n' "$section" "$old_noresolv" "$old_cache" >"$state"
    uci add_list "$section.server=$forwarder"
    uci set "$section.noresolv=1"
    uci set "$section.cachesize=0"
    uci commit dhcp
    /etc/init.d/dnsmasq restart
fi
