#!/bin/sh
# Check subscription staging using fake network and builder commands.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/site"
mkdir -p "$tmp/site/geosite"
printf 'old-geodata\n' >"$tmp/site/geosite/openai.srs"
printf '%s\n' 'https://example.invalid/private-token' >"$tmp/site/subscription.url"
printf '%s\n' 'previous-good' >"$tmp/site/subscription.raw"
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
[ "$MODE" = valid_all ] || exit 1
case "$*" in *'--resolve raw.githubusercontent.com:443:192.0.2.55'*) ;; *) exit 1 ;; esac
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then shift; printf '%s\n' "$MODE" >"$1"; exit 0; fi
    shift
done
exit 1
EOF
cat >"$tmp/site/subscription-probe.sh" <<'EOF'
#!/bin/sh
set -eu
test "$#" -eq 1
test "$(cat)" = https://example.invalid/private-token
case "$MODE" in download_error|malformed) exit 1 ;; esac
mkdir -p "$1"
jq -n '{url:"https://example.invalid/private-token",selected:1,
       nodes:[{status:"working",sing_box:{type:"hysteria2",tag:"candidate"}}]}' >"$1/current.json"
EOF
cat >"$tmp/bin/nslookup" <<'EOF'
#!/bin/sh
[ "$*" = '-type=A raw.githubusercontent.com 192.0.2.53' ] || exit 1
printf '%s\n' 'Name: raw.githubusercontent.com' 'Address: 192.0.2.55'
EOF
cat >"$tmp/site/routecraft-build" <<'EOF'
#!/bin/sh
set -eu
while [ "$#" -gt 0 ]; do
    case "$1" in
        -vpn-outbound) jq -e '.type=="hysteria2"' "$2" >/dev/null; exit ;;
        -probe-vless|-check-subscription) exit 1 ;;
    esac
    shift
done
exit 1
EOF
cat >"$tmp/bin/sing-box" <<'EOF'
#!/bin/sh
[ "${FAIL_CHECK:-0}" != 1 ]
EOF
chmod +x "$tmp/bin/curl" "$tmp/bin/nslookup" "$tmp/site/routecraft-build"
chmod +x "$tmp/bin/sing-box"
PATH="$tmp/bin:$PATH"; export PATH
ROUTECRAFT_DIR="$tmp/site" ROUTECRAFT_EXIT_NODE=100.64.0.1 ROUTECRAFT_DNS_UPSTREAM=192.0.2.53
export ROUTECRAFT_DIR ROUTECRAFT_EXIT_NODE ROUTECRAFT_DNS_UPSTREAM
mkdir "$tmp/site/.update.lock"
printf '%s\n' "$$" >"$tmp/site/.update.lock/owner"
MODE=download_error ROUTECRAFT_LOCK_OWNER=$$; export MODE ROUTECRAFT_LOCK_OWNER
if sh "$repo/poc/start.sh" >"$tmp/out" 2>"$tmp/err"; then echo 'expected download failure' >&2; exit 1; fi
[ -f "$tmp/site/.update.lock/owner" ]
rm "$tmp/site/.update.lock/owner"
rmdir "$tmp/site/.update.lock"
unset ROUTECRAFT_LOCK_OWNER
for MODE in download_error malformed; do
    export MODE
    if sh "$repo/poc/start.sh" >"$tmp/out" 2>"$tmp/err"; then echo 'expected failure' >&2; exit 1; fi
    [ "$(cat "$tmp/site/subscription.raw")" = previous-good ]
    if grep -q private-token "$tmp/out" "$tmp/err"; then echo 'subscription secret leaked' >&2; exit 1; fi
    [ -z "$(find "$tmp/site" -name '.subscription.*' -print)" ]
done
MODE=valid; export MODE
# Subsequent geodata fetch is intentionally failed by the stub.
if sh "$repo/poc/start.sh" >"$tmp/out" 2>"$tmp/err"; then echo 'expected geodata failure' >&2; exit 1; fi
[ "$(cat "$tmp/site/subscription.raw")" = previous-good ]
[ "$(cat "$tmp/site/geosite/openai.srs")" = old-geodata ]
[ -z "$(find "$tmp/site/generations" -mindepth 1 -print)" ]
[ -z "$(find "$tmp/site" -name '.subscription.*' -print)" ]
MODE=valid_all; export MODE
ROUTECRAFT_CONFIG_ONLY=1; export ROUTECRAFT_CONFIG_ONLY
printf 'old candidate\n' >"$tmp/site/sing-box.candidate.json"
FAIL_CHECK=1; export FAIL_CHECK
if sh "$repo/poc/start.sh" >"$tmp/out" 2>"$tmp/err"; then echo 'expected validation failure' >&2; exit 1; fi
[ "$(cat "$tmp/site/subscription.raw")" = previous-good ]
[ "$(cat "$tmp/site/sing-box.candidate.json")" = 'old candidate' ]
[ -z "$(find "$tmp/site/generations" -mindepth 1 -print)" ]
FAIL_CHECK=0; export FAIL_CHECK
sh "$repo/poc/start.sh" >"$tmp/out" 2>"$tmp/err"
[ "$(cat "$tmp/site/subscription.raw")" = previous-good ]
[ "$(cat "$tmp/site/geosite/openai.srs")" = old-geodata ]
[ -n "$(find "$tmp/site/generations" -mindepth 1 -print)" ]
[ -z "$(find "$tmp/site" -name '.subscription.*' -print)" ]
echo 'subscription-staging: passed'
