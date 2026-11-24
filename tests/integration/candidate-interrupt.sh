#!/bin/sh
# Interrupt a staged download and verify owned temporary state is removed.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
pid=
cleanup() { [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/site"
printf 'https://example.invalid/sub\n' >"$tmp/site/subscription.url"
printf 'previous\n' >"$tmp/site/subscription.raw"
printf 'active\n' >"$tmp/site/sing-box.json"
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
: >"$MOCK_READY"
sleep 2
exit 1
EOF
chmod +x "$tmp/bin/curl"
PATH="$tmp/bin:$PATH" ROUTECRAFT_DIR="$tmp/site" ROUTECRAFT_EXIT_NODE=100.64.0.1 ROUTECRAFT_DNS_UPSTREAM=192.0.2.53 MOCK_READY="$tmp/ready"
export PATH ROUTECRAFT_DIR ROUTECRAFT_EXIT_NODE ROUTECRAFT_DNS_UPSTREAM MOCK_READY
sh "$repo/poc/start.sh" >"$tmp/out" 2>"$tmp/err" &
pid=$!
i=0
while [ ! -e "$tmp/ready" ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i+1)); done
[ -e "$tmp/ready" ] || { echo 'download did not start' >&2; exit 1; }
kill -TERM "$pid"
wait "$pid" 2>/dev/null || true
pid=
[ ! -e "$tmp/site/.update.lock" ]
[ -z "$(find "$tmp/site/generations" -mindepth 1 -print)" ]
[ -z "$(find "$tmp/site" -name '.subscription.*' -o -name '.config.*')" ]
[ "$(cat "$tmp/site/subscription.raw")" = previous ]
[ "$(cat "$tmp/site/sing-box.json")" = active ]
echo 'candidate-interrupt: passed'
