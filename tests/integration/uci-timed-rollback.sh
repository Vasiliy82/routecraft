#!/bin/sh
set -eu
[ "${1:-}" = --isolated ] || { echo "Run only on an isolated test VM with --isolated." >&2; exit 2; }
builder=${2:-}
[ "$#" -le 2 ] || { echo 'Usage: uci-timed-rollback.sh --isolated [BUILDER]' >&2; exit 2; }
[ -z "$builder" ] || [ -x "$builder" ] || { echo 'Builder must be executable.' >&2; exit 1; }
config=/etc/config/routecraft_probe
[ ! -e "$config" ] || { echo 'probe config already exists' >&2; exit 1; }
sid=
pending=0
tmp=$(mktemp -d)
cleanup() {
    if [ "$pending" = 1 ] && [ -n "$sid" ]; then ubus call uci rollback "{\"ubus_rpc_session\":\"$sid\"}" >/dev/null 2>&1 || true; fi
    if [ -n "$sid" ]; then ubus call session destroy "{\"ubus_rpc_session\":\"$sid\"}" >/dev/null 2>&1 || true; fi
    rm -f "$config"
    rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
before=$(sha256sum /etc/config/dhcp /etc/config/network)
printf "config test 'case'\n\toption ignore '0'\n\tlist interface 'guest'\n" >"$config"
ubus call uci get '{"config":"routecraft_probe","section":"case"}' >"$tmp/before"
printf '%s\n' '{"options":{"ignore":"1"}}' >"$tmp/plan"
printf '%s\n' '{"section":"case","options":{},"option_lists":{"interface":["guest","lan"]}}' >"$tmp/dns-plan"
sid=$(ubus call session create '{"timeout":60}' | jsonfilter -e '@.ubus_rpc_session')
case "$sid" in *[!a-f0-9]*|'') echo 'invalid session' >&2; exit 1;; esac
ubus call session grant "{\"ubus_rpc_session\":\"$sid\",\"scope\":\"uci\",\"objects\":[[\"routecraft_probe\",\"read\"],[\"routecraft_probe\",\"write\"]]}" >/dev/null
ubus call uci set "{\"ubus_rpc_session\":\"$sid\",\"config\":\"routecraft_probe\",\"section\":\"case\",\"values\":{\"ignore\":\"1\",\"interface\":[\"guest\",\"lan\"]}}" >/dev/null
ubus call uci apply "{\"ubus_rpc_session\":\"$sid\",\"rollback\":true,\"timeout\":5}" >/dev/null
pending=1
[ "$(uci -q get routecraft_probe.case.ignore)" = 1 ]
if [ -n "$builder" ]; then
    ubus call uci get '{"config":"routecraft_probe","section":"case"}' >"$tmp/applied"
    if "$builder" -verify-dhcp-plan "$tmp/plan" -uci-before "$tmp/before" -uci-current "$tmp/applied" >/dev/null 2>&1; then echo 'unrestored value was accepted' >&2; exit 1; fi
    if "$builder" -verify-dns-plan "$tmp/dns-plan" -uci-before "$tmp/before" -uci-current "$tmp/applied" >/dev/null 2>&1; then echo 'unrestored list was accepted' >&2; exit 1; fi
fi
sleep 7
[ "$(uci -q get routecraft_probe.case.ignore)" = 0 ]
pending=0
if [ -n "$builder" ]; then
    ubus call uci get '{"config":"routecraft_probe","section":"case"}' >"$tmp/restored"
    "$builder" -verify-dhcp-plan "$tmp/plan" -uci-before "$tmp/before" -uci-current "$tmp/restored" >/dev/null
    "$builder" -verify-dns-plan "$tmp/dns-plan" -uci-before "$tmp/before" -uci-current "$tmp/restored" >/dev/null
fi
[ "$before" = "$(sha256sum /etc/config/dhcp /etc/config/network)" ]
echo UCI_TIMED_ROLLBACK_PASSED
