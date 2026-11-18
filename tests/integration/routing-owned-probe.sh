#!/bin/sh
# Inspect owned and foreign rules entirely within a temporary network namespace.
set -eu
[ "${1:-}" = --isolated ] && [ "$#" = 2 ] && [ -x "$2" ] || { echo 'Usage: routing-owned-probe.sh --isolated BUILDER' >&2; exit 2; }
ns=routecraft_route_probe
if ip netns list | grep -q "^$ns "; then echo 'probe namespace already exists' >&2; exit 1; fi
tmp=$(mktemp -d)
created=0
cleanup() { [ "$created" = 0 ] || ip netns del "$ns" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
ip netns add "$ns"
created=1
ip -n "$ns" route add local default dev lo table 100
ip -n "$ns" rule add fwmark 0x81 iif lo lookup 100
ip -n "$ns" -j -N rule show >"$tmp/rules"
ip -n "$ns" -j -N -4 route show table all >"$tmp/routes"
"$2" -check-routing-rules "$tmp/rules" -owned-lan lo
"$2" -check-routing-routes "$tmp/routes" -owned-lan lo
if "$2" -check-routing-rules "$tmp/rules" >/dev/null 2>&1; then echo 'unowned rule accepted' >&2; exit 1; fi
if "$2" -check-routing-routes "$tmp/routes" >/dev/null 2>&1; then echo 'unowned route accepted' >&2; exit 1; fi
ip -n "$ns" rule add fwmark 0x80/0xf0 iif lo lookup 200
ip -n "$ns" -j -N rule show >"$tmp/rules"
if "$2" -check-routing-rules "$tmp/rules" -owned-lan lo >/dev/null 2>&1; then echo 'overlapping foreign rule accepted' >&2; exit 1; fi
echo 'routing-owned-probe: passed'
