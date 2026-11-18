#!/bin/sh
# Isolated preflight conflict probe; all routing/firewall commands are stubs.
set -eu
[ "${1:-}" = --isolated ] && [ "$#" = 2 ] || { echo 'Usage: preflight-conflict.sh --isolated BUILDER' >&2; exit 2; }
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
[ -r /etc/openwrt_release ] && [ -x "$2" ] || { echo 'Requires OpenWrt and an executable builder.' >&2; exit 1; }
if [ -x /etc/init.d/routecraft-poc ] && [ -s /etc/routecraft-poc/sing-box.json ]; then echo 'Test requires a VM without an active RouteCraft installation.' >&2; exit 1; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/fake"
cp "$repo/poc/install.sh" "$tmp/install.sh"
cp "$2" "$tmp/bin/routecraft-poc-build"
case "$(uname -m)" in x86_64|amd64) arch=amd64;; aarch64|arm64) arch=arm64;; armv7*) arch=armv7;; *) exit 1;; esac
printf '%s\n' "$arch" >"$tmp/TARGET_ARCH"
MOCK_LAN=$(uci -q get network.lan.device || uci -q get network.lan.ifname)
MOCK_LAN=${MOCK_LAN%% *}; export MOCK_LAN
cat >"$tmp/fake/ip" <<'EOF'
#!/bin/sh
case "$*" in
  '-4 route show default') printf 'default via 192.0.2.1 dev %s\n' "$MOCK_LAN";;
  '-j -N rule show') case "$MOCK_CONFLICT" in rule) echo '[{"table":"100"}]';; mark) echo '[{"fwmark":"0x81","table":"200"}]';; mask) echo '[{"fwmark":"0x80","fwmask":"0xf0","table":"200"}]';; inspect_error) exit 1;; *) echo '[{"fwmark":"0x80000","fwmask":"0xff0000","table":"52"}]';; esac;;
  '-j -N -4 route show table all') case "$MOCK_CONFLICT" in route) echo '[{"type":"2","dst":"default","dev":"lo","table":"100","scope":"254","flags":[]}]';; routes_error) exit 1;; *) echo '[]';; esac;;
  *) exit 1;;
esac
EOF
cat >"$tmp/fake/nft" <<'EOF'
#!/bin/sh
case "$1" in -c) cat >/dev/null; exit 0;; *) exit 1;; esac
EOF
cat >"$tmp/fake/sing-box" <<'EOF'
#!/bin/sh
case "$1" in version) echo mock;; check) exit 0;; *) exit 1;; esac
EOF
chmod 700 "$tmp/fake/"*
PATH="$tmp/fake:$PATH"; export PATH
before=$(sha256sum /etc/config/dhcp /etc/config/network)
for MOCK_CONFLICT in rule mark mask route; do
    export MOCK_CONFLICT
    sh "$tmp/install.sh" --check >"$tmp/out" 2>&1
    grep -q 'CONFLICT: mark 0x81, routing table 100' "$tmp/out"
    if sh "$tmp/install.sh" --activate >"$tmp/out" 2>&1 </dev/null; then echo 'activation accepted routing conflict' >&2; exit 1; fi
    grep -q 'activation refused because of an unmanaged routing conflict' "$tmp/out"
done
MOCK_CONFLICT=none; export MOCK_CONFLICT
sh "$tmp/install.sh" --check >"$tmp/out" 2>&1
if grep -q 'CONFLICT: mark 0x81, routing table 100' "$tmp/out"; then echo 'unrelated mark was rejected' >&2; exit 1; fi
MOCK_CONFLICT=inspect_error; export MOCK_CONFLICT
if sh "$tmp/install.sh" --activate >"$tmp/out" 2>&1 </dev/null; then echo 'activation accepted unreadable rules' >&2; exit 1; fi
grep -q 'cannot inspect numeric policy-routing rules' "$tmp/out"
MOCK_CONFLICT=routes_error; export MOCK_CONFLICT
if sh "$tmp/install.sh" --activate >"$tmp/out" 2>&1 </dev/null; then echo 'activation accepted unreadable routes' >&2; exit 1; fi
grep -q 'cannot inspect numeric routing tables' "$tmp/out"
[ "$before" = "$(sha256sum /etc/config/dhcp /etc/config/network)" ]
echo 'preflight-conflict: passed'
