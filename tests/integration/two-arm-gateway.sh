#!/bin/sh
# The separate-WAN path must preserve router-owned forwarding and NAT.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin"
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
printf 'ip %s\n' "$*" >>"$TEST_DIR/calls"
case "$*" in 'link show dev '*) exit 0;; *) exit 1;; esac
EOF
cat >"$tmp/bin/sysctl" <<'EOF'
#!/bin/sh
printf 'sysctl %s\n' "$*" >>"$TEST_DIR/calls"
case "$*" in '-n net.ipv4.ip_forward') echo "${FORWARD:-1}";; *) exit 1;; esac
EOF
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
printf 'nft %s\n' "$*" >>"$TEST_DIR/calls"
case "$*" in 'list table inet routecraft_poc') [ "${TABLE_EXISTS:-0}" = 1 ];; *) exit 1;; esac
EOF
chmod +x "$tmp/bin/"*
PATH="$tmp/bin:$PATH" TEST_DIR="$tmp" ROUTECRAFT_LAN_INTERFACE=lan0 ROUTECRAFT_WAN_INTERFACE=wan0 ROUTECRAFT_LAN_SUBNET=192.0.2.0/24
export PATH TEST_DIR ROUTECRAFT_LAN_INTERFACE ROUTECRAFT_WAN_INTERFACE ROUTECRAFT_LAN_SUBNET
sh "$repo/poc/direct-gateway.sh" >"$tmp/out" 2>"$tmp/err"
grep -q 'using existing IPv4 forwarding' "$tmp/out"
if grep -Eq 'sysctl -w|nft (-f|delete|add)|ip route' "$tmp/calls"; then echo 'unexpected network change' >&2; exit 1; fi
FORWARD=0; export FORWARD
if sh "$repo/poc/direct-gateway.sh" >"$tmp/out" 2>"$tmp/err"; then echo 'expected forwarding failure' >&2; exit 1; fi
FORWARD=1 TABLE_EXISTS=1; export FORWARD TABLE_EXISTS
if sh "$repo/poc/direct-gateway.sh" >"$tmp/out" 2>"$tmp/err"; then echo 'expected migration failure' >&2; exit 1; fi
echo 'two-arm-gateway: passed'
