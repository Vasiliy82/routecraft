#!/bin/sh
# Temporary, narrowly scoped TCP TPROXY probe on the authorized test gateway.
set -eu

lock=/tmp/routecraft-tproxy-probe
mkdir "$lock" || { echo "Another probe is active" >&2; exit 1; }
table_created=0
route_created=0
alias_route_created=0
rule_created=0
pid=
cleanup() {
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
    [ "$table_created" = 0 ] || nft delete table inet routecraft_probe 2>/dev/null || true
    [ "$rule_created" = 0 ] || ip rule del priority 17263 fwmark 0x7263/0xffffffff lookup 190 2>/dev/null || true
    [ "$route_created" = 0 ] || ip route del local default dev lo table 190 2>/dev/null || true
    [ "$alias_route_created" = 0 ] || ip route del 198.18.0.2/32 dev br-lan 2>/dev/null || true
    rm -f "$lock/config.json" "$lock/sing-box.log"
    rmdir "$lock" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

if nft list table inet routecraft_probe >/dev/null 2>&1 ||
   ip rule show | grep -q '^17263:' ||
   [ -n "$(ip route show table 190 2>/dev/null)" ] ||
   [ -n "$(ip route show exact 198.18.0.2/32)" ]; then
    echo "Probe table, rule priority, or routing table is already in use" >&2
    exit 1
fi
cat >"$lock/config.json" <<'EOF'
{
  "log": {"level": "info"},
  "inbounds": [{"type": "tproxy", "tag": "test-tproxy", "listen": "0.0.0.0", "listen_port": 18083}],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {"final": "direct"}
}
EOF
sing-box check -c "$lock/config.json"
sing-box run -c "$lock/config.json" >"$lock/sing-box.log" 2>&1 &
pid=$!
sleep 1
kill -0 "$pid"
ip route add local default dev lo table 190
route_created=1
ip rule add priority 17263 fwmark 0x7263/0xffffffff lookup 190
rule_created=1
ip route add 198.18.0.2/32 dev br-lan
alias_route_created=1
nft -f - <<'EOF'
table inet routecraft_probe {
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    iifname "br-lan" ip saddr { 192.168.80.242, 198.18.0.2 } ip daddr 1.1.1.1 tcp dport 80 counter tproxy ip to 127.0.0.1:18083 meta mark set 0x7263 accept
    iifname "br-lan" ip saddr 192.168.80.242 ip daddr 1.1.1.1 udp dport 53 counter tproxy ip to 127.0.0.1:18083 meta mark set 0x7263 accept
  }
}
EOF
table_created=1
echo 'READY: send the test request from VM2 within 30 seconds'
sleep 30
echo 'NFT COUNTERS:'
nft list chain inet routecraft_probe prerouting
echo 'SING-BOX LOG:'
cat "$lock/sing-box.log"
