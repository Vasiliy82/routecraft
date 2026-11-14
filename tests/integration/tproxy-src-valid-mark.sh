#!/bin/sh
# Isolated regression: transparent TCP with Linux source validation enabled.
# Run as root on a Linux host with iproute2, nft, sing-box, curl, uhttpd,
# dnsmasq, nslookup, veth and bridge support. Interfaces stay in namespaces.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d /tmp/routecraft-netns.XXXXXX)
gateway=rcg$$
client=rcc$$
server=rcs$$
proxy_pid=
server_pid=
dns_pid=
gateway_created=0
client_created=0
server_created=0
cleanup() {
    [ -z "$proxy_pid" ] || kill "$proxy_pid" 2>/dev/null || true
    [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
    [ -z "$dns_pid" ] || kill "$dns_pid" 2>/dev/null || true
    [ "$client_created" = 0 ] || ip netns del "$client" 2>/dev/null || true
    [ "$server_created" = 0 ] || ip netns del "$server" 2>/dev/null || true
    [ "$gateway_created" = 0 ] || ip netns del "$gateway" 2>/dev/null || true
    rm -f "$work/config.json" "$work/proxy.log" "$work/server.log" "$work/dns.log" "$work/dns.pid" "$work/www/index.html"
    rmdir "$work/www" "$work" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

for tool in ip nft sing-box curl uhttpd dnsmasq nslookup; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 77; }
done
ip netns add "$gateway"
gateway_created=1
ip netns add "$client"
client_created=1
ip netns add "$server"
server_created=1
ip -n "$gateway" link add rc-br type bridge
ip -n "$gateway" link add rc-gc type veth peer name rc-c
ip -n "$gateway" link add rc-gs type veth peer name rc-s
ip -n "$gateway" link set rc-c netns "$client"
ip -n "$gateway" link set rc-s netns "$server"
ip -n "$gateway" link set rc-gc master rc-br
ip -n "$gateway" link set rc-gs master rc-br
for iface in lo rc-br rc-gc rc-gs; do ip -n "$gateway" link set "$iface" up; done
for iface in lo rc-c; do ip -n "$client" link set "$iface" up; done
for iface in lo rc-s; do ip -n "$server" link set "$iface" up; done
ip -n "$gateway" addr add 10.42.0.1/24 dev rc-br
ip -n "$client" addr add 10.42.0.2/24 dev rc-c
ip -n "$server" addr add 10.42.0.3/24 dev rc-s
ip -n "$server" addr add 203.0.113.2/32 dev lo
ip -n "$gateway" -6 addr add fd42:42::1/64 dev rc-br nodad
ip -n "$client" -6 addr add fd42:42::2/64 dev rc-c nodad
ip -n "$server" -6 addr add fd42:42::3/64 dev rc-s nodad
ip -n "$server" -6 addr add 2001:db8::2/128 dev lo nodad
ip -n "$client" route add default via 10.42.0.1
ip -n "$gateway" route add default via 10.42.0.3
ip -n "$client" -6 route add default via fd42:42::1 dev rc-c
ip -n "$gateway" -6 route add 2001:db8::2/128 via fd42:42::3 dev rc-br
ip -n "$gateway" rule add priority 29000 fwmark 0x82 lookup 101
ip netns exec "$gateway" sysctl -w net.ipv4.ip_forward=1 >/dev/null
ip netns exec "$gateway" sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

mkdir "$work/www"
printf 'routecraft-isolated-ok\n' >"$work/www/index.html"
ip netns exec "$server" uhttpd -f -p 203.0.113.2:18080 -p '[2001:db8::2]:18080' -h "$work/www" >"$work/server.log" 2>&1 &
server_pid=$!
ip netns exec "$server" dnsmasq -k -C /dev/null --no-resolv --no-hosts --user=root --address=/routecraft.test/203.0.113.2 --listen-address=203.0.113.2 --bind-interfaces --pid-file="$work/dns.pid" >"$work/dns.log" 2>&1 &
dns_pid=$!
cat >"$work/config.json" <<'EOF'
{"log":{"level":"info"},"inbounds":[{"type":"tproxy","tag":"gateway","listen":"0.0.0.0","listen_port":12345}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}
EOF
ip netns exec "$gateway" sing-box run -c "$work/config.json" >"$work/proxy.log" 2>&1 &
proxy_pid=$!
sleep 1
kill -0 "$server_pid"
kill -0 "$dns_pid"
kill -0 "$proxy_pid"
ip netns exec "$gateway" env ROUTECRAFT_LAN_INTERFACE=rc-br sh "$root/poc/tproxy-gateway.sh"
ip netns exec "$gateway" env ROUTECRAFT_LAN_INTERFACE=rc-br sh "$root/poc/tproxy-gateway.sh"
count=$(ip -n "$gateway" rule show | grep -Fc 'fwmark 0x81 iif rc-br lookup 100' || true)
[ "$count" = 1 ] || { echo "Expected one scoped policy rule, found $count" >&2; exit 1; }
ip -n "$gateway" route get 10.42.0.2 mark 0x81 | grep -q 'dev rc-br' || {
    echo 'Marked reverse lookup did not select the LAN route' >&2; exit 1;
}

for value in 0 1; do
    ip netns exec "$gateway" sysctl -w net.ipv4.conf.all.src_valid_mark="$value" >/dev/null
    before=$(grep -c 'inbound/tproxy\[gateway\]: inbound connection from' "$work/proxy.log" || true)
    echo "Testing client traffic with src_valid_mark=$value"
    if ! ip netns exec "$client" curl -4 --noproxy '*' -fsS --connect-timeout 2 --max-time 4 http://203.0.113.2:18080/ | grep -qx routecraft-isolated-ok; then
        cat "$work/proxy.log" >&2
        exit 1
    fi
    after=$(grep -c 'inbound/tproxy\[gateway\]: inbound connection from' "$work/proxy.log" || true)
    [ "$after" -gt "$before" ] || { echo 'Request bypassed the transparent proxy' >&2; exit 1; }
    before_udp=$(grep -c 'inbound/tproxy\[gateway\]: inbound packet connection from' "$work/proxy.log" || true)
    if ! answer=$(ip netns exec "$client" nslookup -type=a -timeout=3 routecraft.test 203.0.113.2); then
        printf '%s\n' "$answer" >&2
        cat "$work/dns.log" >&2
        cat "$work/proxy.log" >&2
        exit 1
    fi
    printf '%s\n' "$answer" | grep -q 'Name:.*routecraft.test' || { echo 'DNS answer missing' >&2; exit 1; }
    after_udp=$(grep -c 'inbound/tproxy\[gateway\]: inbound packet connection from' "$work/proxy.log" || true)
    [ "$after_udp" -gt "$before_udp" ] || { echo 'DNS query bypassed the transparent proxy' >&2; exit 1; }
done
# If sing-box stops, a failed TPROXY lookup must not bypass the policy and
# silently forward the same connection directly.
kill "$proxy_pid"
wait "$proxy_pid" 2>/dev/null || true
proxy_pid=
if ip netns exec "$client" curl -4 --noproxy '*' -fsS --connect-timeout 2 --max-time 3 http://203.0.113.2:18080/ >/dev/null 2>&1; then
    echo 'Traffic bypassed TPROXY after the proxy stopped' >&2; exit 1
fi
if ip netns exec "$client" nslookup -type=a -timeout=1 routecraft.test 203.0.113.2 >/dev/null 2>&1; then
    echo 'UDP traffic bypassed TPROXY after the proxy stopped' >&2; exit 1
fi
if ! ip netns exec "$client" curl -g -6 --noproxy '*' -fsS --connect-timeout 2 --max-time 4 'http://[2001:db8::2]:18080/' | grep -qx routecraft-isolated-ok; then
    echo 'IPv6 traffic was unexpectedly blocked by the IPv4 rule' >&2; exit 1
fi
ip -n "$gateway" rule del fwmark 0x81 lookup 100
if ip -n "$gateway" rule show | grep -q 'fwmark 0x81'; then
    echo 'RouteCraft policy rule was not removed' >&2; exit 1
fi
ip -n "$gateway" rule show | grep -q 'fwmark 0x82 lookup 101' || {
    echo 'Unrelated policy rule was removed' >&2; exit 1;
}
echo 'IPv4 TCP/UDP work with src_valid_mark=0 and 1; proxy failure does not bypass policy; IPv6 is unaffected.'
