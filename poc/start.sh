#!/bin/sh
# Start the test-only RouteCraft PoC on an OpenWrt gateway.
set -eu
dir=${ROUTECRAFT_POC_DIR:-/tmp/routecraft-poc}
url_file=${ROUTECRAFT_SUBSCRIPTION_FILE:-$dir/subscription.url}
key_file=${ROUTECRAFT_HEADSCALE_KEY_FILE:-$dir/headscale.key}
control=${ROUTECRAFT_HEADSCALE_URL:-https://hs1.vasiliy.me:9443}
exit_node=${ROUTECRAFT_EXIT_NODE:-100.64.0.8}

mkdir -p "$dir/geosite" "$dir/geoip"
umask 077
curl -fsSL --connect-timeout 5 --max-time 30 "$(cat "$url_file")" -o "$dir/subscription.raw"
base=https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo
for name in openai cursor anthropic youtube telegram whatsapp; do
    curl -fsSL --connect-timeout 5 --max-time 30 "$base/geosite/$name.srs" -o "$dir/geosite/$name.srs"
done
curl -fsSL --connect-timeout 5 --max-time 30 "$base/geoip/telegram.srs" -o "$dir/geoip/telegram.srs"
extra=https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box
curl -fsSL --connect-timeout 5 --max-time 30 "$extra/rule-set-geosite/geosite-ru-blocked.srs" -o "$dir/geosite/ru-blocked.srs"
curl -fsSL --connect-timeout 5 --max-time 30 "$extra/rule-set-geoip/geoip-ru-blocked.srs" -o "$dir/geoip/ru-blocked.srs"

"$dir/routecraft-poc-build" -policy "$dir/policy.yaml" -subscription "$dir/subscription.raw" \
    -headscale-key "$key_file" -data "$dir" -headscale "$control" -exit-node "$exit_node" \
    -output "$dir/sing-box.json"
sing-box check -c "$dir/sing-box.json"

if [ -f "$dir/sing-box.pid" ]; then
    pid=$(cat "$dir/sing-box.pid")
    case "$pid" in *[!0-9]*|'') echo 'Invalid PoC PID' >&2; exit 1;; esac
    if [ -r "/proc/$pid/cmdline" ] && tr '\0' ' ' <"/proc/$pid/cmdline" | grep -Fq "$dir/sing-box.json"; then
        kill "$pid"
        sleep 1
    fi
fi
setsid /usr/bin/sing-box run -c "$dir/sing-box.json" </dev/null >"$dir/sing-box.log" 2>&1 &
pid=$!
echo "$pid" > "$dir/sing-box.pid"
sleep 3
kill -0 "$pid"
sh "$dir/direct-gateway.sh"
sh "$dir/tproxy-gateway.sh"
echo "PoC running; log: $dir/sing-box.log"
