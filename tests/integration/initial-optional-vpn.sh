#!/bin/sh
# First-install mode must not use stale subscriptions or change active state.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/site"
cat >"$tmp/site/routecraft-build" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$ROUTECRAFT_DIR/args"
EOF
cat >"$tmp/bin/sing-box" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$tmp/site/routecraft-build" "$tmp/bin/"*
PATH="$tmp/bin:$PATH"; export PATH
ROUTECRAFT_DIR="$tmp/site" ROUTECRAFT_INITIAL_OPTIONAL_VPN=1 ROUTECRAFT_CONFIG_ONLY=1 ROUTECRAFT_DNS_UPSTREAM=192.0.2.53
export ROUTECRAFT_DIR ROUTECRAFT_INITIAL_OPTIONAL_VPN ROUTECRAFT_CONFIG_ONLY ROUTECRAFT_DNS_UPSTREAM
printf 'old secret data\n' >"$tmp/site/subscription.raw"
sh "$repo/poc/start.sh" >"$tmp/out" 2>"$tmp/err"
grep -q -- '-omit-unavailable-initial-vpn' "$tmp/site/args"
[ "$(cat "$tmp/site/subscription.raw")" = 'old secret data' ]
[ ! -e "$tmp/site/sing-box.json" ]
mkdir "$tmp/site/.update.lock"
if sh "$repo/poc/start.sh" >"$tmp/out" 2>"$tmp/err"; then echo 'expected lock failure' >&2; exit 1; fi
grep -q 'another RouteCraft update' "$tmp/err"
[ -d "$tmp/site/.update.lock" ]
rmdir "$tmp/site/.update.lock"
cat >"$tmp/site/subscription-probe.sh" <<'EOF'
#!/bin/sh
exit 1
EOF
printf '%s\n' 'https://example.invalid/private-token' >"$tmp/site/subscription.url"
sh "$repo/poc/start.sh" >"$tmp/out" 2>"$tmp/err"
[ "$(cat "$tmp/site/subscription.raw")" = 'old secret data' ]
if grep -q private-token "$tmp/out" "$tmp/err"; then echo 'subscription secret leaked' >&2; exit 1; fi
# The builder gets an empty subscription argument, never the old saved data.
if grep -q 'subscription.raw' "$tmp/site/args"; then echo 'stale subscription was used' >&2; exit 1; fi
printf 'existing\n' >"$tmp/site/sing-box.json"
if sh "$repo/poc/start.sh" >"$tmp/out" 2>"$tmp/err"; then echo 'existing config must fail' >&2; exit 1; fi
grep -q 'only available before first activation' "$tmp/err"
[ "$(cat "$tmp/site/sing-box.json")" = existing ]
echo 'initial-optional-vpn: passed'
