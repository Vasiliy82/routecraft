#!/bin/sh
set -eu
umask 077

usage() {
    cat <<'EOF'
Usage: subscription.sh set url URL
       subscription.sh set url --stdin
       subscription.sh set hwid ID
       subscription.sh get url|hwid|selected
       subscription.sh check|update
EOF
}

die() { printf '%s\n' "$1" >&2; exit 1; }
progress() { if [ -t 2 ]; then printf '%s\n' "$1" >&2; fi; }

dir=${ROUTECRAFT_DIR:-/etc/routecraft}
service=${ROUTECRAFT_SERVICE:-/etc/init.d/routecraft}
engine="$(dirname "$0")/subscription-poc.sh"
state="$dir/subscription"
probe="$state/probe"
active="$dir/sing-box.json"
lock="$dir/.update.lock"

[ "$#" -gt 0 ] || { usage >&2; exit 1; }
case "$1" in -h|--help) usage; exit 0 ;; esac
[ -d "$dir" ] || die 'RouteCraft installation directory is missing.'
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 ||
    die 'Subscription updater requires jq 1.8+ and flock.'
[ ! -L "$state" ] && [ ! -L "$probe" ] || die 'Invalid subscription state directory.'
mkdir -p "$probe"
for private in "$state" "$probe"; do
    [ "$(ls -ld "$private" | cut -c1-10)" = drwx------ ] ||
        die 'Subscription state directories must have mode 0700.'
done
exec 8>"$state/lock"
flock -n 8 || die 'Another subscription operation is running.'

staged= work= owns_lock=0 rollback=0
cleanup() {
    code=$?
    trap - EXIT
    trap '' HUP INT TERM
    set +e
    if [ "$rollback" -eq 1 ]; then
        selection_restored=0
        if [ -f "$work/previous-selected.json" ]; then
            mv -f "$work/previous-selected.json" "$state/selected.json" && selection_restored=1
        else
            rm -f "$state/selected.json" && selection_restored=1
        fi
        if cp -p "$work/previous.json" "$work/restore.json" && mv -f "$work/restore.json" "$active" &&
            "$service" restart 8>&- >/dev/null 2>&1 && [ "$selection_restored" -eq 1 ] &&
            wait_for_service; then
            printf '%s\n' 'Previous configuration restored and RouteCraft restarted.' >&2
        else
            printf '%s\n' 'Automatic rollback failed. Inspect RouteCraft service and the rollback workspace.' >&2
            printf 'Workspace: %s\n' "$work" >&2
            work=
        fi
    fi
    [ -z "$staged" ] || rm -f "$staged"
    if [ -n "$work" ]; then rm -f "$work/"*; rmdir "$work"; fi
    if [ "$owns_lock" -eq 1 ]; then rm -f "$lock/owner"; rmdir "$lock"; fi
    exit "$code"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

save() {
    staged=$(mktemp "$state/.write.XXXXXX")
    cat "$1" >"$staged" && mv -f "$staged" "$2" || die 'Cannot save subscription state.'
    staged=
}

wait_for_service() {
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if "$service" status 8>&- >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    return 1
}

verify_egress() {
    for attempt in 1 2 3 4 5 6; do
        if "$service" status 8>&- >/dev/null 2>&1 &&
            curl -q --noproxy '' --proxy "socks5h://127.0.0.1:$port" \
                --fail --silent --max-time 5 --max-filesize 1024 \
                'https://api.ipify.org?format=json' >"$work/live.json" 2>/dev/null &&
            live_ip=$(jq -ers '
                select(length == 1) | .[0].ip | strings |
                select((split(".") | length == 4 and all(.[];
                    length >= 1 and length <= 3 and all(explode[]; . >= 48 and . <= 57) and
                    (tonumber <= 255))))
            ' "$work/live.json" 2>/dev/null); then
            return 0
        fi
        sleep 1
    done
    return 1
}

case "$1" in
    set)
        [ "$#" -eq 3 ] || die 'Use set url URL, set url --stdin or set hwid ID.'
        case "$2" in
            url)
                if [ "$3" = --stdin ]; then url=$(head -c 8193 | sed 's/\r$//'); else url=$3; fi
                printf '%s' "$url" | sh "$engine" --validate-url
                staged=$(mktemp "$state/.write.XXXXXX")
                printf '%s\n' "$url" >"$staged"
                mv -f "$staged" "$state/url"
                staged= ;;
            hwid)
                case "$3" in ''|*[!A-Za-z0-9=-]*) die 'Invalid HWID.' ;; esac
                [ "${#3}" -ge 10 ] && [ "${#3}" -le 64 ] || die 'Invalid HWID.'
                # Share the probe lock in case the engine is running directly.
                exec 9>"$probe/lock"
                flock -n 9 || die 'A subscription probe is running.'
                staged=$(mktemp "$probe/.write.XXXXXX")
                printf '%s\n' "$3" >"$staged"
                mv -f "$staged" "$probe/hwid"
                staged= ;;
            *) die 'Unknown subscription setting.' ;;
        esac
        exit 0 ;;
    get)
        [ "$#" -eq 2 ] || die 'Use get url, get hwid or get selected.'
        case "$2" in
            url) file="$state/url" ;;
            hwid) file="$probe/hwid" ;;
            selected) file="$state/selected.json" ;;
            *) die 'Unknown subscription setting.' ;;
        esac
        [ -s "$file" ] || die 'No saved value.'
        cat "$file"
        exit 0 ;;
    check|update) [ "$#" -eq 1 ] || die 'Unexpected argument.' ;;
    *) usage >&2; exit 1 ;;
esac

[ -s "$state/url" ] || die 'Set the subscription URL first.'
sh "$engine" --state-dir "$probe" --probe-timeout 1 --require-egress-ip --url-stdin <"$state/url"
if [ "$1" = check ]; then
    progress 'Check complete. Use update to apply the selected node.'
    exit 0
fi

progress 'Comparing the selected node with the active sing-box configuration…'
mkdir "$lock" 2>/dev/null || die 'Another RouteCraft update is running, or its lock needs inspection.'
owns_lock=1
printf '%s\n' "$$" >"$lock/owner"
[ -f "$active" ] && [ ! -L "$active" ] || die 'Active sing-box configuration is missing.'
[ -x "$service" ] || die 'RouteCraft service is missing.'
work=$(mktemp -d "$dir/.subscription-apply.XXXXXX")

jq -e '.selected as $n | select($n > 0) |
    .nodes[$n-1] | select(.status == "working" and (.sing_box | type) == "object") |
    {protocol,name,uri,egress_ip,sing_box}
' "$probe/current.json" >"$work/selected.json" 2>/dev/null || die 'Invalid selected subscription node.'

jq -e '
    [.outbounds[] | select(.tag == "vpn-sub")] |
    if length == 1 then .[0] else error("missing or duplicate vpn-sub") end
' "$active" >"$work/outbound.json" 2>/dev/null || die 'Expected exactly one active vpn-sub outbound.'

jq -e --slurpfile selected "$work/selected.json" --slurpfile existing "$work/outbound.json" '
    $existing[0] as $old |
    (if $old.type == "selector" then $old.outbounds else [] end) as $children |
    if ($children | type) != "array" or
        any($children[]; if type == "string" then startswith("sub-") | not else true end) or
        ($old.type | IN("selector","vless","vmess","trojan","shadowsocks","hysteria2","tuic") | not) then
        error("unrecognized subscription outbound")
    else
        ([.outbounds[] | select(.tag == $old.default)][0] // $old) as $dial |
        ($selected[0].sing_box | .tag = "vpn-sub" |
            if $dial.domain_resolver != null then .domain_resolver = $dial.domain_resolver else . end) as $next |
        .outbounds |= map(select(.tag as $tag | $children | index($tag) == null) |
            if .tag == "vpn-sub" then $next else . end)
    end
' "$active" >"$work/candidate.json" 2>/dev/null || die 'Cannot replace the subscription outbound safely.'

if jq -es 'length == 2 and .[0] == .[1]' "$active" "$work/candidate.json" >/dev/null 2>&1; then
    if ! jq -es 'length == 2 and .[0].sing_box == .[1].sing_box and .[0].name == .[1].name' \
        "$state/selected.json" "$work/selected.json" >/dev/null 2>&1; then
        save "$work/selected.json" "$state/selected.json"
    fi
    printf '%s\n' 'VPN outbound unchanged. Restart not needed.'
    exit 0
fi

port=$(jq -er '
    select(any(.route.rules[]; .outbound == "vpn-sub" and
        ((.inbound // []) | if type == "string" then . == "test-vless" else index("test-vless") != null end))) |
    [.inbounds[] | select(.tag == "test-vless" and .type == "mixed" and .listen == "127.0.0.1") | .listen_port] |
    select(length == 1) | .[0] | select(type == "number" and . >= 1 and . <= 65535 and . == floor)
' "$active" 2>/dev/null) || die 'The active configuration has no RouteCraft loopback VPN test listener.'
"$service" status 8>&- >/dev/null 2>&1 || die 'RouteCraft service is stopped.'
progress 'Validating the replacement sing-box configuration…'
sing-box check -c "$work/candidate.json" >"$work/check.log" 2>&1 || die 'sing-box rejected the replacement configuration.'
cp -p "$active" "$work/previous.json"
if [ -f "$state/selected.json" ]; then cp -p "$state/selected.json" "$work/previous-selected.json"; fi
rollback=1
mv -f "$work/candidate.json" "$active"
progress 'Restarting RouteCraft with the new VPN outbound…'
"$service" restart 8>&- >"$work/restart.log" 2>&1 || die 'RouteCraft restart failed.'
progress 'Checking HTTPS through the restarted service…'
verify_egress || die 'Live HTTPS probe through the restarted VPN outbound failed.'
save "$work/selected.json" "$state/selected.json"
rollback=0
printf 'VPN outbound updated. Live IP: %s\n' "$live_ip"
