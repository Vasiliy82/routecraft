#!/bin/sh
# Exercise the session helper against real rpcd, rewriting its package to an
# explicitly created dummy config. Never touches real DHCP or DNS settings.
set -eu
[ "${1:-}" = --isolated ] && [ "$#" = 2 ] || { echo 'Usage: uci-session-probe.sh --isolated BUILDER' >&2; exit 2; }
[ "$(id -u)" = 0 ] && [ -x "$2" ] || { echo 'Requires root and an executable builder.' >&2; exit 1; }
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
config=/etc/config/routecraft_probe
[ ! -e "$config" ] || { echo 'probe config already exists' >&2; exit 1; }
real_ubus=$(command -v ubus)
tmp=$(mktemp -d)
session_started=0
cleanup() {
    if [ "$session_started" = 1 ]; then sh "$repo/poc/uci-dhcp-session.sh" rollback >/dev/null 2>&1 || true; fi
    rm -f "$config"
    rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/site/.update.lock"
printf '%s\n' "$$" >"$tmp/site/.update.lock/owner"
cp "$2" "$tmp/site/routecraft-build"
chmod 700 "$tmp/site/routecraft-build"
cat >"$tmp/bin/ubus" <<'EOF'
#!/bin/sh
if [ "$#" = 4 ] && [ "$1" = call ]; then
    payload=$(printf '%s' "$4" | sed 's/"dhcp"/"routecraft_probe"/g')
    exec "$REAL_UBUS" "$1" "$2" "$3" "$payload"
fi
exec "$REAL_UBUS" "$@"
EOF
chmod 700 "$tmp/bin/ubus"
REAL_UBUS=$real_ubus PATH="$tmp/bin:$PATH" ROUTECRAFT_DIR="$tmp/site"
export REAL_UBUS PATH ROUTECRAFT_DIR
before=$(sha256sum /etc/config/dhcp /etc/config/network)
printf "config dhcp 'lan'\n\toption ignore '0'\n\toption dhcpv4 'server'\n\toption dhcpv6 'server'\nconfig dnsmasq 'dns_main'\n\tlist interface 'guest'\n" >"$config"
printf '%s\n' '{"options":{"ignore":"1","dhcpv4":"disabled","dhcpv6":"disabled"}}' >"$tmp/dhcp-plan"
printf '%s\n' '{"section":"dns_main","options":{},"option_lists":{"interface":["guest","lan"]}}' >"$tmp/dns-plan"
sh "$repo/poc/uci-dhcp-session.sh" prepare "$tmp/dhcp-plan" lan "$tmp/dns-plan" >/dev/null
session_started=1
sh "$repo/poc/uci-dhcp-session.sh" apply >/dev/null
[ "$(uci -q get routecraft_probe.lan.ignore)" = 1 ]
sh "$repo/poc/uci-dhcp-session.sh" rollback >/dev/null
session_started=0
[ "$(uci -q get routecraft_probe.lan.ignore)" = 0 ]
[ "$(uci -q get routecraft_probe.dns_main.interface)" = guest ]
[ ! -e "$tmp/site/.uci-dhcp-session" ]
sh "$repo/poc/uci-dhcp-session.sh" prepare "$tmp/dhcp-plan" lan "$tmp/dns-plan" >/dev/null
session_started=1
ROUTECRAFT_UCI_TIMEOUT=5 sh "$repo/poc/uci-dhcp-session.sh" apply >/dev/null
[ "$(uci -q get routecraft_probe.lan.ignore)" = 1 ]
sleep 7
# The explicit rollback call sees an expired timer, then verifies the snapshot.
sh "$repo/poc/uci-dhcp-session.sh" rollback >/dev/null
session_started=0
[ "$(uci -q get routecraft_probe.lan.ignore)" = 0 ]
[ "$(uci -q get routecraft_probe.dns_main.interface)" = guest ]
[ ! -e "$tmp/site/.uci-dhcp-session" ]
[ "$before" = "$(sha256sum /etc/config/dhcp /etc/config/network)" ]
echo 'uci-session-probe: passed (dummy package only)'
