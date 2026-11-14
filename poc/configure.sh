#!/bin/sh
# Collect site-specific settings and build a candidate without applying routes.
set -eu

dir=${ROUTECRAFT_POC_DIR:-/etc/routecraft-poc}
[ "$(id -u)" = 0 ] || { echo 'Run configure.sh as root.' >&2; exit 1; }
[ -x "$dir/routecraft-poc-build" ] || { echo 'Install the bundle first with install.sh --install.' >&2; exit 1; }

lan_if=$(uci -q get network.lan.device 2>/dev/null || uci -q get network.lan.ifname 2>/dev/null || true)
lan_if=${lan_if%% *}
dns_default=$(uci -q get network.lan.dns 2>/dev/null | awk '{print $1}')
dns_default=${dns_default:-$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $3}')}

# Only inspect the local client. Do not copy its state or credentials: sing-box
# registers its own Tailscale device with the supplied pre-auth key.
control_default=https://controlplane.tailscale.com
exit_default=
if command -v tailscale >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
    ts_status=$(tailscale status --json 2>/dev/null || true)
    ts_state=$(printf '%s' "$ts_status" | jsonfilter -e '@.BackendState' 2>/dev/null || true)
    if [ "$ts_state" = Running ]; then
        if ts_prefs=$(tailscale debug prefs 2>/dev/null); then
            ts_control=$(printf '%s' "$ts_prefs" | jsonfilter -e '@.ControlURL' 2>/dev/null || true)
            [ -z "$ts_control" ] || control_default=$ts_control
        else
            echo 'WARNING: could not read the running Tailscale client control URL; verify the proposed URL.' >&2
        fi
        ts_addresses=$(printf '%s' "$ts_status" | jsonfilter -e '@.ExitNodeStatus.TailscaleIPs[*]' 2>/dev/null || true)
        for address in $ts_addresses; do
            address=${address%%/*}
            case "$address" in *:*) continue;; *[!0-9.]*|'') continue;; esac
            exit_default=$address
            break
        done
        # If this client has not selected an exit node, suggest the sole
        # approved candidate, but never choose arbitrarily among several.
        if [ -z "$exit_default" ]; then
            ts_count=$(printf '%s' "$ts_status" | jsonfilter -e '@.Peer[@.ExitNodeOption=true].ExitNodeOption' 2>/dev/null | grep -c '^true$' || true)
            if [ "$ts_count" = 1 ]; then
                ts_addresses=$(printf '%s' "$ts_status" | jsonfilter -e '@.Peer[@.ExitNodeOption=true].TailscaleIPs[*]' 2>/dev/null || true)
                for address in $ts_addresses; do
                    address=${address%%/*}
                    case "$address" in *:*) continue;; *[!0-9.]*|'') continue;; esac
                    exit_default=$address
                    break
                done
            elif [ "${ts_count:-0}" -gt 1 ]; then
                echo 'Multiple Tailscale Exit Nodes are available; choose one using tailscale status.' >&2
            fi
        fi
    fi
fi

ask() {
    label=$1
    default=$2
    if [ -n "$default" ]; then printf '%s [%s]: ' "$label" "$default" >&2
    else printf '%s: ' "$label" >&2; fi
    IFS= read -r answer
    printf '%s' "${answer:-$default}"
}

ask_secret() {
    label=$1
    printf '%s: ' "$label" >&2
    interactive=0
    if [ -t 0 ]; then
        if ! command -v stty >/dev/null 2>&1; then
            echo 'ERROR: stty is missing. Run the RouteCraft installer again to install its dependencies.' >&2
            return 1
        fi
        stty -echo || { echo 'ERROR: could not disable terminal echo for secret input.' >&2; return 1; }
        interactive=1
    fi
    if IFS= read -r answer; then
        read_status=0
    else
        read_status=$?
    fi
    if [ "$interactive" -eq 1 ]; then
        stty echo || { echo 'ERROR: could not restore terminal echo.' >&2; return 1; }
        printf '\n' >&2
    fi
    [ "$read_status" -eq 0 ] || return "$read_status"
    printf '%s' "$answer"
}

lan_if=$(ask 'LAN interface' "$lan_if")
case "$lan_if" in *[!a-zA-Z0-9_.-]*|'') echo 'Invalid interface name.' >&2; exit 1;; esac
lan_subnet=$(ip -4 route show dev "$lan_if" scope link 2>/dev/null | awk 'NR==1 {print $1}')
lan_subnet=$(ask 'LAN IPv4 subnet in CIDR form' "$lan_subnet")
dns_upstream=$(ask 'DNS upstream IPv4' "$dns_default")
headscale=$(ask 'Tailscale or Headscale control URL' "$control_default")
exit_node=$(ask 'Tailscale Exit Node name or IP' "$exit_default")
subscription=$(ask_secret 'VLESS subscription URL')
auth_key=$(ask_secret 'Tailscale or Headscale pre-auth key')

case "$lan_if" in *[!a-zA-Z0-9_.-]*|'') echo 'Invalid interface name.' >&2; exit 1;; esac
case "$lan_subnet" in *[!0-9./]*|*/*/*|'') echo 'Invalid LAN subnet.' >&2; exit 1;; esac
case "$dns_upstream" in *[!0-9.]*|*.*.*.*.*|'') echo 'Invalid DNS IPv4 address.' >&2; exit 1;; esac
case "$headscale" in https://*[!a-zA-Z0-9.:/-]*|https://|'') echo 'Invalid Tailscale or Headscale URL.' >&2; exit 1;; https://*) ;; *) echo 'Control URL must use HTTPS.' >&2; exit 1;; esac
case "$exit_node" in *[!a-zA-Z0-9_.:-]*|'') echo 'Invalid Exit Node.' >&2; exit 1;; esac
case "$subscription" in https://*|http://*) ;; *) echo 'Subscription URL must use HTTP or HTTPS.' >&2; exit 1;; esac
[ -n "$auth_key" ] || { echo 'Tailscale or Headscale key cannot be empty.' >&2; exit 1; }
ip link show dev "$lan_if" >/dev/null

mkdir -p "$dir"
umask 077
printf 'ROUTECRAFT_LAN_INTERFACE=%s\nROUTECRAFT_LAN_SUBNET=%s\nROUTECRAFT_DNS_UPSTREAM=%s\nROUTECRAFT_HEADSCALE_URL=%s\nROUTECRAFT_EXIT_NODE=%s\n' \
    "$lan_if" "$lan_subnet" "$dns_upstream" "$headscale" "$exit_node" >"$dir/site.candidate.env"
printf '%s\n' "$subscription" >"$dir/subscription.url"
printf '%s\n' "$auth_key" >"$dir/headscale.key"
chmod 600 "$dir/site.candidate.env" "$dir/subscription.url" "$dir/headscale.key"

ROUTECRAFT_POC_DIR="$dir" ROUTECRAFT_SITE_ENV="$dir/site.candidate.env" ROUTECRAFT_CONFIG_ONLY=1 sh "$dir/start.sh"
echo "Configuration candidate prepared. No active config, service, route, or firewall rule was changed."
printf 'Activate it now? (y/N): '
IFS= read -r answer
case "$answer" in y|Y|yes|YES) sh "$dir/install.sh" --activate ;; *) echo "Candidate remains at $dir/sing-box.candidate.json.";; esac
