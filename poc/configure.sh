#!/bin/sh
# Collect site-specific settings and build a candidate without applying routes.
set -eu

dir=${ROUTECRAFT_DIR:-/etc/routecraft}
secret_dir=${ROUTECRAFT_SECRET_DIR:-/root/routecraft-config}
exec 3>&1
printf '%s\n' 'INFO: Reading local network and Tailscale settings.'
[ "$(id -u)" = 0 ] || { echo 'Run configure.sh as root.' >&2; exit 1; }
[ -x "$dir/routecraft-build" ] || { echo 'Install the bundle first with install.sh --install.' >&2; exit 1; }

lan_if=$(uci -q get network.lan.device 2>/dev/null || uci -q get network.lan.ifname 2>/dev/null || true)
lan_if=${lan_if%% *}
wan_if=$(uci -q get network.wan.device 2>/dev/null || uci -q get network.wan.ifname 2>/dev/null || true)
wan_if=${wan_if%% *}
wan_if=${wan_if:-$(ip -4 route show default 2>/dev/null | awk 'NR==1 {for (i=1;i<NF;i++) if ($i == "dev") print $(i+1)}')}
dns_default=$(uci -q get network.lan.dns 2>/dev/null | awk '{print $1}')
dns_default=${dns_default:-$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $3}')}

# Only inspect the local client. Do not copy its state or credentials: sing-box
# registers its own Tailscale device with the supplied pre-auth key.
control_default=https://controlplane.tailscale.com
exit_default=
active_exit=
if [ -s "$dir/sing-box.json" ]; then
    active_exit=$(jq -r '[.endpoints[]? | select(.tag=="tailscale-exit" and .type=="tailscale") |
        .exit_node | strings][0] // empty' "$dir/sing-box.json" 2>/dev/null || true)
fi
ts_status=
ts_state=
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
            elif [ "${ts_count:-0}" -gt 1 ] && [ -z "$active_exit" ]; then
                echo 'Multiple Tailscale Exit Nodes are available; choose one using tailscale status.' >&2
            fi
        fi
    fi
fi
if [ -n "$active_exit" ]; then
    exit_default="$active_exit"
    printf '%s\n' 'INFO: Using the active RouteCraft Exit Node as the default.'
fi

ask() {
    label=$1
    default=$2
    if [ -n "$default" ]; then printf '%s [%s]: ' "$label" "$default" >&2
    else printf '%s: ' "$label" >&2; fi
    IFS= read -r answer || return 1
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

read_secret() {
    secret_file="$secret_dir/$2"
    if [ ! -e "$secret_file" ] && [ ! -L "$secret_file" ]; then
        ask_secret "$1"
        return
    fi
    [ -f "$secret_file" ] && [ -r "$secret_file" ] && [ ! -L "$secret_file" ] || {
        echo "ERROR: expected a readable regular file at $secret_file." >&2
        return 1
    }
    secret_value=$(cat "$secret_file") || return 1
    carriage_return=$(printf '\r')
    secret_value=${secret_value%"$carriage_return"}
    case "$secret_value" in
        ''|*[[:space:]]*) echo "ERROR: expected one nonempty value in $secret_file." >&2; return 1 ;;
    esac
    printf 'INFO: Using %s from %s.\n' "$1" "$secret_file" >&3
    printf '%s' "$secret_value"
}

ask_interface() {
    interface_label=$1
    interface_default=$2
    if ! printf '%s\n' "$available_interfaces" | grep -Fx -- "$interface_default" >/dev/null; then
        interface_default=
    fi
    while :; do
        interface_choice=$(ask "$interface_label" "$interface_default") || return 1
        case "$interface_choice" in
            *[!a-zA-Z0-9_.-]*|'') ;;
            *) if printf '%s\n' "$available_interfaces" | grep -Fx -- "$interface_choice" >/dev/null &&
                  "$dir/routecraft-build" -check-interface "$interface_choice" >/dev/null 2>&1; then
                   printf '%s' "$interface_choice"
                   return
               fi ;;
        esac
        echo 'That device is unavailable or cannot be selected; choose one from the list.' >&2
        interface_default=
    done
}

# Only called after a newly installed client is explicitly selected for
# registration. The system and embedded identities need separate keys if
# those keys are single-use. Avoid putting the system key in process arguments.
connect_new_system_tailscale() (
    umask 077
    system_key_file=$(mktemp /tmp/routecraft-ts-key.XXXXXX) || exit 1
    trap 'rm -f "$system_key_file"' EXIT
    trap 'exit 1' HUP INT TERM
    printf '%s\n' "$system_key" >"$system_key_file"
    ts_init=${ROUTECRAFT_TS_INIT:-/etc/init.d/tailscale}
    [ -x "$ts_init" ] || { echo 'ERROR: Tailscale service is unavailable.' >&2; exit 1; }
    "$ts_init" enable && "$ts_init" start &&
        tailscale up --login-server="$system_control" --auth-key="file:$system_key_file" --accept-dns=false --accept-routes=false --timeout=30s
)

echo 'dnsmasq rebind protection can block DNS answers containing private addresses.' >&2
printf 'Disable dnsmasq rebind protection during activation? [Y/n]: ' >&2
IFS= read -r rebind_answer
case "$rebind_answer" in ''|y|Y|yes|YES) disable_rebind=1;; *) disable_rebind=0;; esac
echo 'The current dnsmasq setting remains unchanged while the candidate is prepared.' >&2

echo 'Selectable devices (bridge ports and unsupported virtual devices are omitted):' >&2
available_interfaces=$("$dir/routecraft-build" -list-interfaces) || { echo 'ERROR: cannot list network devices.' >&2; exit 1; }
[ -n "$available_interfaces" ] || { echo 'ERROR: no selectable network devices found.' >&2; exit 1; }
printf '%s\n' "$available_interfaces" >&2
wan_if=$(ask_interface 'WAN interface' "$wan_if") || { echo 'ERROR: interface input ended.' >&2; exit 1; }
lan_if=$(ask_interface 'LAN interface' "$lan_if") || { echo 'ERROR: interface input ended.' >&2; exit 1; }
lan_subnet=$(ip -4 route show dev "$lan_if" scope link 2>/dev/null | awk 'NR==1 {print $1}')
lan_subnet=$(ask 'LAN IPv4 subnet in CIDR form' "$lan_subnet")
dns_upstream=$(ask 'DNS upstream IPv4' "$dns_default")
first_install=0
if [ ! -e "$dir/sing-box.json" ] && [ ! -e "$dir/site.env" ]; then first_install=1; fi
headscale=
exit_node=
auth_key=
if [ "$first_install" = 1 ]; then
    if ! command -v tailscale >/dev/null 2>&1; then
        printf 'Tailscale is not installed. Install it from the configured OpenWrt feed? (y/N): ' >&2
        IFS= read -r install_ts
        case "$install_ts" in
            y|Y|yes|YES)
                ts_installed=0
                ts_existing_state=0
                if [ -e /etc/config/tailscale ] || [ -e /etc/init.d/tailscale ] || [ -e /etc/tailscale/tailscaled.state ]; then ts_existing_state=1; fi
                if command -v apk >/dev/null 2>&1; then
                    if apk update && apk add tailscale; then ts_installed=1; else echo 'WARNING: Tailscale installation failed.' >&2; fi
                elif command -v opkg >/dev/null 2>&1; then
                    if opkg update && opkg install tailscale; then ts_installed=1; else echo 'WARNING: Tailscale installation failed.' >&2; fi
                else
                    echo 'WARNING: no supported OpenWrt package manager found.' >&2
                fi
                if [ "$ts_installed" = 1 ] && command -v tailscale >/dev/null 2>&1; then
                    if [ "$ts_existing_state" = 1 ] || [ -e /etc/tailscale/tailscaled.state ]; then
                        echo 'Existing Tailscale state was found; it will not be modified automatically.' >&2
                    else
                        echo 'Connecting creates a system Tailscale identity that remains even if RouteCraft activation is cancelled.' >&2
                        echo 'Use separate authentication keys for the system and embedded identities if keys are single-use.' >&2
                        printf 'Connect the newly installed system Tailscale client now? (y/N): ' >&2
                        IFS= read -r connect_ts
                        case "$connect_ts" in
                            y|Y|yes|YES)
                                system_control=$(ask 'Tailscale or Headscale control URL for the system client' "$control_default")
                                case "$system_control" in https://*[!a-zA-Z0-9.:/-]*|https://|'') echo 'Invalid Tailscale or Headscale URL.' >&2; exit 1;; https://*) ;; *) echo 'Control URL must use HTTPS.' >&2; exit 1;; esac
                                system_key=$(ask_secret 'System Tailscale pre-auth key')
                                [ -n "$system_key" ] || { echo 'System Tailscale key cannot be empty.' >&2; exit 1; }
                                if connect_new_system_tailscale; then control_default=$system_control; else echo 'WARNING: system Tailscale could not be connected; no Exit Node will be assumed.' >&2; fi
                                system_key=
                                ;;
                        esac
                    fi
                fi
                ;;
        esac
    fi
    if command -v tailscale >/dev/null 2>&1; then
        ts_status=$(tailscale status --json 2>/dev/null || true)
    fi
    candidates=$(printf '%s' "$ts_status" | "$dir/routecraft-build" -list-exit-nodes /dev/stdin 2>/dev/null || true)
    if [ -n "$candidates" ] && [ "$candidates" != '[]' ] && [ "$candidates" != null ]; then
        echo 'Online approved Tailscale Exit Nodes (address and name):' >&2
        printf '%s\n' "$candidates" >&2
        printf 'Use a Tailscale Exit Node? [Y/n]: ' >&2
        IFS= read -r use_ts
        case "$use_ts" in
            ''|y|Y|yes|YES)
                if ! printf '%s' "$ts_status" | "$dir/routecraft-build" -list-exit-nodes /dev/stdin -check-exit-node "$exit_default" >/dev/null 2>&1; then exit_default=; fi
                while :; do
                    exit_node=$(ask 'Exit Node address from the list' "$exit_default") || exit 1
                    ts_status=$(tailscale status --json 2>/dev/null || true)
                    if [ -n "$exit_node" ] && printf '%s' "$ts_status" | "$dir/routecraft-build" -list-exit-nodes /dev/stdin -check-exit-node "$exit_node" >/dev/null 2>&1; then break; fi
                    echo 'Exit Node is unavailable or not approved; choose an address from the list.' >&2
                    exit_default=
                done
                headscale=$(ask 'Tailscale or Headscale control URL' "$control_default")
                auth_key=$(read_secret 'Tailscale or Headscale pre-auth key' tailscale-pre-auth-key)
                ;;
        esac
    else
        echo 'No online approved Exit Node was found; the initial Tailscale rule will be omitted.' >&2
        echo 'If Tailscale was just installed, sign in and rerun the wizard to discover nodes.' >&2
    fi
else
    headscale=$(ask 'Tailscale or Headscale control URL' "$control_default")
    exit_node=$(ask 'Tailscale Exit Node name or IP' "$exit_default")
fi
if [ "$first_install" = 1 ]; then
    echo 'INFO: A VPN subscription URL is optional on the first installation.'
fi
subscription=$(read_secret 'VPN subscription URL' vless-subscription-url) || exit 1
if [ "$first_install" != 1 ]; then
    auth_key=$(read_secret 'Tailscale or Headscale pre-auth key' tailscale-pre-auth-key) || exit 1
fi

case "$lan_if" in *[!a-zA-Z0-9_.-]*|'') echo 'Invalid interface name.' >&2; exit 1;; esac
case "$lan_subnet" in *[!0-9./]*|*/*/*|'') echo 'Invalid LAN subnet.' >&2; exit 1;; esac
case "$dns_upstream" in *[!0-9.]*|*.*.*.*.*|'') echo 'Invalid DNS IPv4 address.' >&2; exit 1;; esac
if [ -n "$exit_node" ]; then
    case "$headscale" in https://*[!a-zA-Z0-9.:/-]*|https://|'') echo 'Invalid Tailscale or Headscale URL.' >&2; exit 1;; https://*) ;; *) echo 'Control URL must use HTTPS.' >&2; exit 1;; esac
    case "$exit_node" in *[!a-zA-Z0-9_.:-]*) echo 'Invalid Exit Node.' >&2; exit 1;; esac
    [ -n "$auth_key" ] || { echo 'Tailscale or Headscale key cannot be empty.' >&2; exit 1; }
fi
case "$subscription" in
    https://*|http://*) ;;
    '') [ ! -e "$dir/sing-box.json" ] && [ ! -e "$dir/site.env" ] || { echo 'An existing installation requires a subscription; no active policy was changed.' >&2; exit 1; } ;;
    *) echo 'Subscription URL must use HTTP or HTTPS.' >&2; exit 1;;
esac
if [ "$first_install" != 1 ] && [ -z "$exit_node" ]; then echo 'Invalid Exit Node.' >&2; exit 1; fi
ip link show dev "$lan_if" >/dev/null

if [ -n "$subscription" ] && [ ! -s "$dir/subscription/probe/hwid" ] &&
    { [ -e "$secret_dir/subscription-hwid" ] || [ -L "$secret_dir/subscription-hwid" ]; }; then
    hwid=$(read_secret 'subscription HWID' subscription-hwid) || exit 1
    sh "$dir/subscription.sh" set hwid "$hwid"
fi

mkdir -p "$dir"
umask 077
lock_dir="$dir/.update.lock"
mkdir "$lock_dir" 2>/dev/null || { echo 'ERROR: another RouteCraft update is running, or its lock needs inspection.' >&2; exit 1; }
printf '%s\n' "$$" >"$lock_dir/owner"
trap 'rm -f "$lock_dir/owner" "$dir/candidate.sha256.tmp"; rmdir "$lock_dir" 2>/dev/null || true' EXIT
trap 'exit 1' HUP INT TERM
initial_optional=0
if [ ! -e "$dir/sing-box.json" ] && [ ! -e "$dir/site.env" ]; then initial_optional=1; fi
if [ -z "$subscription" ] && [ "$initial_optional" != 1 ]; then
    echo 'ERROR: an existing installation requires a subscription; no active policy was changed.' >&2
    exit 1
fi
if [ "$first_install" = 1 ] && [ "$initial_optional" != 1 ]; then
    echo 'ERROR: an active installation appeared; rerun the wizard.' >&2; exit 1
fi
printf 'ROUTECRAFT_LAN_INTERFACE=%s\nROUTECRAFT_WAN_INTERFACE=%s\nROUTECRAFT_LAN_SUBNET=%s\nROUTECRAFT_DNS_UPSTREAM=%s\nROUTECRAFT_HEADSCALE_URL=%s\nROUTECRAFT_EXIT_NODE=%s\nROUTECRAFT_DISABLE_REBIND=%s\n' \
    "$lan_if" "$wan_if" "$lan_subnet" "$dns_upstream" "$headscale" "$exit_node" "$disable_rebind" >"$dir/site.candidate.env"
printf '%s\n' "$subscription" >"$dir/subscription.candidate.url"
printf '%s\n' "$auth_key" >"$dir/headscale.candidate.key"
chmod 600 "$dir/site.candidate.env" "$dir/subscription.candidate.url" "$dir/headscale.candidate.key"

printf '%s\n' 'INFO: Preparing a candidate configuration for the selected interfaces and VPNs.'
ROUTECRAFT_DIR="$dir" ROUTECRAFT_SITE_ENV="$dir/site.candidate.env" \
    ROUTECRAFT_SUBSCRIPTION_FILE="$dir/subscription.candidate.url" ROUTECRAFT_HEADSCALE_KEY_FILE="$dir/headscale.candidate.key" \
    ROUTECRAFT_CONFIG_ONLY=1 ROUTECRAFT_INITIAL_OPTIONAL_VPN="$initial_optional" ROUTECRAFT_LOCK_OWNER="$$" sh "$dir/start.sh"
sha256sum "$dir/sing-box.candidate.json" "$dir/site.candidate.env" "$dir/subscription.candidate.url" "$dir/headscale.candidate.key" >"$dir/candidate.sha256.tmp"
mv -f "$dir/candidate.sha256.tmp" "$dir/candidate.sha256"
rm -f "$lock_dir/owner"
rmdir "$lock_dir"
trap - EXIT HUP INT TERM
echo "Configuration candidate prepared. No active config, service, route, or firewall rule was changed."
sh "$dir/install.sh" --activate
