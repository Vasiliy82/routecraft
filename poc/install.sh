#!/bin/sh
# Stage or explicitly activate a RouteCraft OpenWrt PoC bundle.
set -eu

bundle_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mode=${1:---check}
target_arch=$(cat "$bundle_dir/TARGET_ARCH" 2>/dev/null || true)
builder="$bundle_dir/bin/routecraft-poc-build"
[ -f "$builder" ] || builder="$bundle_dir/routecraft-poc-build"
system_arch=$(uname -m)
case "$system_arch" in
    x86_64|amd64) detected_arch=amd64 ;;
    aarch64|arm64) detected_arch=arm64 ;;
    armv7l|armv7*) detected_arch=armv7 ;;
    *) detected_arch=unsupported ;;
esac

fail=0
dependency_missing=0
conflict=0
topology_supported=1
if [ ! -r /etc/openwrt_release ]; then
    echo 'ERROR: this helper targets OpenWrt.'
    fail=1
else
    . /etc/openwrt_release
    echo "OpenWrt: ${DISTRIB_RELEASE:-unknown} (${DISTRIB_TARGET:-unknown})"
fi
echo "CPU: $system_arch; bundle: ${target_arch:-missing}"
echo "Persistent space: $(df -h / | awk 'NR==2 {print $4 " free on " $1}')"

if [ "$detected_arch" = unsupported ] || [ "$target_arch" != "$detected_arch" ]; then
    echo "ERROR: bundle does not match supported target architecture ($detected_arch)."
    fail=1
fi
if [ ! -f "$builder" ]; then
    echo 'ERROR: bundled routecraft-poc-build is missing.'
    fail=1
fi

for command in sing-box curl ip nft sysctl stty; do
    if command -v "$command" >/dev/null 2>&1; then
        echo "OK: $command found"
    else
        echo "MISSING: $command"
        fail=1
        dependency_missing=1
    fi
done
if command -v sing-box >/dev/null 2>&1; then
    version=$(sing-box version 2>&1 | head -n 2 | tr '\n' ' ')
    echo "sing-box: $version"
    probe="/tmp/routecraft-tailscale-check.$$"
    trap 'rm -f "$probe"' EXIT HUP INT TERM
    cat >"$probe" <<'EOF'
{"log":{"level":"error"},"endpoints":[{"type":"tailscale","tag":"probe","state_directory":"/tmp/routecraft-tailscale-probe","hostname":"routecraft-probe","control_url":"https://example.invalid","auth_key":"tskey-auth-test","exit_node":"100.64.0.1","accept_routes":false,"system_interface":false}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}
EOF
    if sing-box check -c "$probe" >/dev/null 2>&1; then
        echo 'OK: sing-box accepts the embedded Tailscale endpoint.'
    else
        echo 'MISSING: sing-box with embedded Tailscale endpoint support.'
        fail=1
    fi
    rm -f "$probe"
    trap - EXIT HUP INT TERM
fi

lan_if=$(uci -q get network.lan.device 2>/dev/null || uci -q get network.lan.ifname 2>/dev/null || true)
lan_if=${lan_if%% *}
gateway=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $3}')
upstream_if=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i == "dev") print $(i+1)}')
echo "LAN interface: ${lan_if:-unknown}; upstream: ${gateway:-unknown} via ${upstream_if:-unknown}"
if [ -z "$lan_if" ] || [ -z "$upstream_if" ] || [ "$lan_if" != "$upstream_if" ]; then
    echo 'UNSUPPORTED: this PoC expects one LAN interface for clients and upstream; WAN/LAN interface groups are not handled.'
    topology_supported=0
    fail=1
fi

owned=0
if [ -x /etc/init.d/routecraft-poc ] && [ -s /etc/routecraft-poc/sing-box.json ]; then
    owned=1
fi
if ip rule show 2>/dev/null | grep -q 'fwmark 0x81 lookup 100' && [ "$owned" -ne 1 ]; then
    echo 'CONFLICT: fwmark 0x81/table 100 is already used outside the installed RouteCraft PoC.'
    conflict=1
fi
if nft list table inet routecraft_tproxy >/dev/null 2>&1 && [ "$owned" -ne 1 ]; then
    echo 'CONFLICT: nft table inet routecraft_tproxy exists without the RouteCraft service.'
    conflict=1
fi
if nft list table inet routecraft_poc >/dev/null 2>&1 && [ "$owned" -ne 1 ]; then
    echo 'CONFLICT: nft table inet routecraft_poc exists without the RouteCraft service.'
    conflict=1
fi
if { awk '$2 ~ /:3039$/ && $4 == "0A" { found=1 } END { exit !found }' /proc/net/tcp /proc/net/tcp6 2>/dev/null || awk '$2 ~ /:3039$/ { found=1 } END { exit !found }' /proc/net/udp /proc/net/udp6 2>/dev/null; } && [ "$owned" -ne 1 ]; then
    echo 'CONFLICT: TCP/UDP port 12345 is already in use outside the RouteCraft service.'
    conflict=1
fi
if ! nft -c -f - >/dev/null 2>&1 <<'EOF'
table inet routecraft_probe {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        meta l4proto tcp tproxy ip to 127.0.0.1:12345 meta mark set 0x81 accept
    }
}
EOF
then
    echo 'MISSING: nftables cannot validate the TPROXY rule (kernel support/package may be absent).'
    fail=1
    dependency_missing=1
else
    echo 'OK: nftables TPROXY expression is supported.'
fi
if command -v pidof >/dev/null 2>&1; then
    for pid in $(pidof sing-box 2>/dev/null || true); do
        command_line=$(tr '\000' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
        case "$command_line" in */etc/routecraft-poc/sing-box.json*) ;; *) echo "CONFLICT: unmanaged sing-box process $pid is running."; conflict=1 ;; esac
    done
fi
if [ "$conflict" -eq 0 ]; then
    echo 'No known RouteCraft mark/table/process conflict found.'
fi

# Only the mutating install mode may add required packages. Do it after the
# read-only conflict checks and never run a blanket system upgrade.
if [ "$mode" = --install ] && [ "$dependency_missing" -ne 0 ] && [ "${ROUTECRAFT_DEPS_ATTEMPTED:-0}" != 1 ]; then
    [ "$(id -u)" = 0 ] || { echo 'ERROR: install requires root.'; exit 1; }
    [ -r /etc/openwrt_release ] || { echo 'ERROR: dependency installation is supported only on OpenWrt.'; exit 1; }
    [ "$detected_arch" != unsupported ] && [ "$target_arch" = "$detected_arch" ] || { echo 'ERROR: unsupported system or mismatched bundle.'; exit 1; }
    [ "$topology_supported" -eq 1 ] || { echo 'ERROR: this package only supports the single-interface gateway topology.'; exit 1; }
    [ "$conflict" -eq 0 ] || { echo 'ERROR: resolve routing conflicts before installing packages.'; exit 1; }
    packages=''
    for package in sing-box curl ca-bundle coreutils-stty ip-full nftables-json kmod-nft-tproxy; do
        if command -v apk >/dev/null 2>&1; then
            apk info -e "$package" >/dev/null 2>&1 && continue
        elif opkg status "$package" 2>/dev/null | grep -q '^Status:.* installed'; then
            continue
        fi
        packages="$packages $package"
    done
    if [ -z "$packages" ]; then
        echo 'Required packages are already installed; checking the runtime features.'
    elif command -v apk >/dev/null 2>&1; then
        echo "Installing missing RouteCraft packages with apk:$packages (no system upgrade)."
        apk update || exit 1
        apk add $packages || exit 1
    elif command -v opkg >/dev/null 2>&1; then
        echo "Installing missing RouteCraft packages with opkg:$packages (no system upgrade)."
        opkg update || exit 1
        opkg install $packages || exit 1
    else
        echo 'ERROR: neither apk nor opkg is available; cannot install dependencies.' >&2
        exit 1
    fi
    case " $packages " in
        *' sing-box '*)
            if [ -x /etc/init.d/sing-box ]; then
                echo 'Disabling the standalone sing-box service; RouteCraft manages the sing-box process.'
                /etc/init.d/sing-box disable || exit 1
            fi
            ;;
    esac
    ROUTECRAFT_DEPS_ATTEMPTED=1 sh "$bundle_dir/install.sh" --install
    exit $?
fi

case "$mode" in
    --check)
        [ "$fail" -eq 0 ] || exit 1
        echo 'Read-only preflight complete; no files or network settings changed.'
        [ "$conflict" -eq 0 ] || echo 'Staging is allowed; activation will be refused until conflicts are resolved.'
        ;;
    --install)
        [ "$(id -u)" = 0 ] || { echo 'ERROR: install requires root.'; exit 1; }
        [ "$fail" -eq 0 ] || exit 1
        destination=/etc/routecraft-poc
        if [ -d "$destination" ]; then
            backup="/root/routecraft-backup-$(date +%Y%m%d-%H%M%S)"
            mkdir -p "$backup"
            cp -a "$destination" "$backup/"
            echo "Existing RouteCraft directory backed up to $backup."
        fi
        mkdir -p "$destination"
        cp -f "$builder" "$destination/routecraft-poc-build"
        for file in TARGET_ARCH configure.sh install.sh start.sh direct-gateway.sh tproxy-gateway.sh routecraft-poc.init policy.yaml; do
            [ ! -f "$bundle_dir/$file" ] || cp -f "$bundle_dir/$file" "$destination/$file"
        done
        chmod 700 "$destination/routecraft-poc-build"
        chmod 755 "$destination"/*.sh "$destination"/routecraft-poc.init
        echo "Bundle staged at $destination. No service, routes, or firewall rules were changed."
        [ "$conflict" -eq 0 ] || echo 'Resolve the reported conflict before activation.'
        ;;
    --activate)
        [ "$(id -u)" = 0 ] || { echo 'ERROR: activation requires root.'; exit 1; }
        [ "$fail" -eq 0 ] || exit 1
        [ "$conflict" -eq 0 ] || { echo 'ERROR: activation refused because of an unmanaged routing conflict.'; exit 1; }
        destination=/etc/routecraft-poc
        candidate="$destination/sing-box.candidate.json"
        active="$destination/sing-box.json"
        if [ -s "$candidate" ]; then
            sing-box check -c "$candidate"
        elif [ -s "$active" ]; then
            sing-box check -c "$active"
        else
            echo 'ERROR: configure.sh has not produced a validated candidate.'
            exit 1
        fi
        printf 'This starts RouteCraft routing on this gateway. Type ACTIVATE to continue: '
        IFS= read -r confirmation
        [ "$confirmation" = ACTIVATE ] || { echo 'Activation cancelled; active config unchanged.'; exit 1; }
        backup="/root/routecraft-backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$backup"
        had_config=0
        had_service=0
        had_site=0
        [ ! -s "$active" ] || had_config=1
        [ ! -f /etc/init.d/routecraft-poc ] || had_service=1
        [ ! -f "$destination/site.env" ] || had_site=1
        [ ! -s "$active" ] || cp -p "$active" "$backup/sing-box.json"
        [ ! -f /etc/init.d/routecraft-poc ] || cp -p /etc/init.d/routecraft-poc "$backup/routecraft-poc.init"
        [ ! -f "$destination/site.env" ] || cp -p "$destination/site.env" "$backup/site.env"
        if [ -s "$candidate" ]; then
            cp -p "$candidate" "$active"
        fi
        [ ! -s "$destination/site.candidate.env" ] || cp -p "$destination/site.candidate.env" "$destination/site.env"
        cp -f "$destination/routecraft-poc.init" /etc/init.d/routecraft-poc
        chmod 755 /etc/init.d/routecraft-poc
        service_ok=0
        echo "RouteCraft activation: previous service file present: $had_service."
        echo 'RouteCraft activation: enabling the service.'
        if /etc/init.d/routecraft-poc enable; then
            echo 'RouteCraft activation: restarting the service via procd.'
            if /etc/init.d/routecraft-poc restart; then
                echo 'RouteCraft activation: restart returned; checking the service and process.'
                sleep 2
                if /etc/init.d/routecraft-poc status >/dev/null 2>&1 && ps w | grep -F "$active" | grep -v grep >/dev/null; then
                    service_ok=1
                fi
            else
                echo 'ERROR: RouteCraft service restart command failed.' >&2
            fi
        else
            echo 'ERROR: enabling the RouteCraft service failed.' >&2
        fi
        if [ "$service_ok" -ne 1 ]; then
            echo 'ERROR: service did not start; restoring the prior config.' >&2
            /etc/init.d/routecraft-poc stop >/dev/null 2>&1 || true
            if [ "$had_config" -eq 1 ]; then
                cp -p "$backup/sing-box.json" "$active"
            else
                rm -f "$active"
            fi
            if [ "$had_site" -eq 1 ]; then
                cp -p "$backup/site.env" "$destination/site.env"
            else
                rm -f "$destination/site.env"
            fi
            if [ "$had_service" -eq 1 ]; then
                cp -p "$backup/routecraft-poc.init" /etc/init.d/routecraft-poc
                chmod 755 /etc/init.d/routecraft-poc
                /etc/init.d/routecraft-poc enable >/dev/null 2>&1 || true
                /etc/init.d/routecraft-poc restart || true
            else
                /etc/init.d/routecraft-poc disable >/dev/null 2>&1 || true
                rm -f /etc/init.d/routecraft-poc
            fi
            exit 1
        fi
        /etc/init.d/routecraft-poc status
        echo "RouteCraft activated. Recovery copy: $backup"
        ;;
    *)
        echo 'Usage: sh install.sh [--check|--install|--activate]' >&2
        exit 2
        ;;
esac
