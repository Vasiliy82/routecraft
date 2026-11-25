#!/bin/sh
# Start the test-only RouteCraft PoC on an OpenWrt gateway.
set -eu
dir=${ROUTECRAFT_DIR:-/tmp/routecraft}
umask 077
mkdir -p "$dir"
lock_dir="$dir/.update.lock"
owns_lock=0
if [ -n "${ROUTECRAFT_LOCK_OWNER:-}" ] && [ "$ROUTECRAFT_LOCK_OWNER" = "$PPID" ] &&
   [ "$(cat "$lock_dir/owner" 2>/dev/null || true)" = "$ROUTECRAFT_LOCK_OWNER" ]; then
    : # The calling wizard holds the same lock while creating its files.
else
    mkdir "$lock_dir" 2>/dev/null || { echo 'ERROR: another RouteCraft update is running, or its lock needs inspection.' >&2; exit 1; }
    owns_lock=1
    printf '%s\n' "$$" >"$lock_dir/owner"
fi
generation_tmp=
candidate_tmp=
subscription_tmp=
trap 'if [ -n "$candidate_tmp" ]; then rm -f "$candidate_tmp"; fi; if [ -n "$subscription_tmp" ]; then rm -f "$subscription_tmp"; fi; if [ -n "$generation_tmp" ]; then rm -rf "$generation_tmp"; fi; if [ "$owns_lock" = 1 ]; then rm -f "$lock_dir/owner"; rmdir "$lock_dir" 2>/dev/null || true; fi' EXIT
trap 'exit 1' HUP INT TERM
site_env=${ROUTECRAFT_SITE_ENV:-$dir/site.env}
if [ -f "$site_env" ]; then
    . "$site_env"
fi
export ROUTECRAFT_LAN_INTERFACE ROUTECRAFT_LAN_SUBNET ROUTECRAFT_WAN_INTERFACE
url_file=${ROUTECRAFT_SUBSCRIPTION_FILE:-$dir/subscription.url}
key_file=${ROUTECRAFT_HEADSCALE_KEY_FILE:-$dir/headscale.key}
control=${ROUTECRAFT_HEADSCALE_URL:-https://controlplane.tailscale.com}
exit_node=${ROUTECRAFT_EXIT_NODE:-}
dns_upstream=${ROUTECRAFT_DNS_UPSTREAM:-}
[ -n "$dns_upstream" ] || { echo 'ERROR: set ROUTECRAFT_DNS_UPSTREAM.' >&2; exit 1; }
initial_optional=${ROUTECRAFT_INITIAL_OPTIONAL_VPN:-0}
if [ "$initial_optional" = 1 ]; then
    [ "${ROUTECRAFT_CONFIG_ONLY:-0}" = 1 ] && [ ! -e "$dir/sing-box.json" ] && [ ! -e "$dir/site.env" ] || {
        echo 'ERROR: optional initial VPN mode is only available before first activation.' >&2; exit 1;
    }
else
    [ -n "$exit_node" ] || { echo 'ERROR: set ROUTECRAFT_EXIT_NODE.' >&2; exit 1; }
fi
output="$dir/sing-box.json"
if [ "${ROUTECRAFT_CONFIG_ONLY:-0}" = 1 ]; then
    output="$dir/sing-box.candidate.json"
fi

if [ "$initial_optional" = 1 ] && { [ -e "$dir/sing-box.json" ] || [ -e "$dir/site.env" ]; }; then
    echo 'ERROR: active configuration appeared during setup.' >&2; exit 1
fi
mkdir -p "$dir/generations"
generation_tmp=$(mktemp -d "$dir/generations/generation.XXXXXX")
mkdir -p "$generation_tmp/geosite" "$generation_tmp/geoip"
candidate_tmp=$(mktemp "$dir/.config.XXXXXX")
# Download and validate in a private temporary file. A failed refresh must not
# truncate the last usable subscription, even when the server returns HTTP 200
# with an unsupported or malformed payload. Never include the URL in errors.
subscription_path=
subscription_url=
[ ! -s "$url_file" ] || subscription_url=$(cat "$url_file")
if [ -n "$subscription_url" ]; then
    case "$subscription_url" in
        *[[:space:]]*) echo 'ERROR: subscription URL must be a single value.' >&2; exit 1 ;;
    esac
    subscription_tmp=$(mktemp "$dir/.subscription.XXXXXX")
    subscription_config=$(printf '%s' "$subscription_url" | sed 's/[\\"]/\\&/g')
    if printf 'url = "%s"\n' "$subscription_config" |
        curl -q -fLs --proto '=http,https' --proto-redir '=http,https' --connect-timeout 5 --max-time 30 --config - -o "$subscription_tmp" &&
        "$dir/routecraft-build" -check-subscription -subscription "$subscription_tmp"; then
        subscription_path="$subscription_tmp"
    else
        echo 'WARNING: VLESS subscription could not be loaded or has no supported nodes; previous data was retained.' >&2
        rm -f "$subscription_tmp"
        subscription_tmp=
    fi
fi
if [ -z "$subscription_path" ]; then
    if [ "$initial_optional" != 1 ]; then
        echo 'ERROR: a valid VLESS subscription is required.' >&2
        exit 1
    fi
    echo 'VLESS is unavailable. Continuing the first installation without a VLESS outbound.' >&2
fi
base=https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo
if [ "$initial_optional" != 1 ] || [ -n "$exit_node" ]; then
    for name in openai cursor anthropic; do
        curl -fsSL --connect-timeout 5 --max-time 30 "$base/geosite/$name.srs" -o "$generation_tmp/geosite/$name.srs"
    done
fi
extra=https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box
if [ "$initial_optional" != 1 ] || [ -n "$subscription_path" ]; then
    for name in youtube telegram whatsapp; do
        curl -fsSL --connect-timeout 5 --max-time 30 "$base/geosite/$name.srs" -o "$generation_tmp/geosite/$name.srs"
    done
    curl -fsSL --connect-timeout 5 --max-time 30 "$base/geoip/telegram.srs" -o "$generation_tmp/geoip/telegram.srs"
    curl -fsSL --connect-timeout 5 --max-time 30 "$extra/rule-set-geosite/geosite-ru-blocked.srs" -o "$generation_tmp/geosite/ru-blocked.srs"
    curl -fsSL --connect-timeout 5 --max-time 30 "$extra/rule-set-geoip/geoip-ru-blocked.srs" -o "$generation_tmp/geoip/ru-blocked.srs"
fi

set --
if [ "$initial_optional" = 1 ]; then set -- -omit-unavailable-initial-vpn; fi
ROUTECRAFT_TAILSCALE_STATE_DIR="$dir/tailscale-state" "$dir/routecraft-build" "$@" -policy "$dir/policy.yaml" -subscription "$subscription_path" \
    -headscale-key "$key_file" -data "$generation_tmp" -headscale "$control" -exit-node "$exit_node" \
    -dns "$dns_upstream" -output "$candidate_tmp"
sing-box check -c "$candidate_tmp"
if [ "${ROUTECRAFT_CONFIG_ONLY:-0}" != 1 ] &&
    { [ -f "$dir/dnsmasq-split.state" ] || [ -n "$(jsonfilter -i "$candidate_tmp" -e '@.inbounds[@.tag="routecraft-dns"].listen_port')" ]; }; then
    echo 'ERROR: Split DNS configuration must be staged and activated with install.sh --activate.' >&2
    exit 1
fi
mv -f "$candidate_tmp" "$output"
# The validated configuration refers to this immutable generation by path.
generation_tmp=
if [ -n "$subscription_tmp" ]; then
    mv -f "$subscription_tmp" "$dir/subscription.raw"
fi
if [ "${ROUTECRAFT_CONFIG_ONLY:-0}" = 1 ]; then
    echo "Candidate is ready at $output; active config and routes were not changed."
    exit 0
fi

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
