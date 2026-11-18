#!/bin/sh
# Prepare or finish an isolated UCI DHCP transaction. This helper is not yet
# wired into installer activation; callers must hold the RouteCraft lock.
set -eu
mode=${1:-}
dir=${ROUTECRAFT_POC_DIR:-/etc/routecraft-poc}
state="$dir/.uci-dhcp-session"
fail() { echo "ERROR: $*" >&2; exit 1; }
[ "$(cat "$dir/.update.lock/owner" 2>/dev/null || true)" = "$PPID" ] || fail 'caller must hold the RouteCraft update lock'
read_session() {
    [ -s "$state/session" ] || fail 'no pending DHCP session'
    sid=$(cat "$state/session")
    case "$sid" in *[!a-f0-9]*|'') fail 'invalid UCI session';; esac
    [ "${#sid}" = 32 ] || fail 'invalid UCI session length'
}
case "$mode" in
    prepare)
        [ "$#" = 3 ] || [ "$#" = 4 ] || fail 'usage: prepare DHCP_PLAN DHCP_SECTION [DNS_PLAN]'
        plan=$2; section=$3
        dns_plan=${4:-}
        case "$section" in *[!a-zA-Z0-9_]*|'') fail 'invalid DHCP section';; esac
        [ -s "$plan" ] || fail 'DHCP plan is missing'
        umask 077
        mkdir -p "$dir"
        mkdir "$state" 2>/dev/null || fail 'a DHCP session already exists'
        sid=
        cleanup_prepare() {
            if [ -n "$sid" ]; then ubus call session destroy "{\"ubus_rpc_session\":\"$sid\"}" >/dev/null 2>&1 || true; fi
            rm -f "$state/session" "$state/request" "$state/applied" "$state/before" "$state/current" "$state/plan" "$state/section" "$state/dns-plan" "$state/dns-section" "$state/dns-before" "$state/dns-current"
            rmdir "$state" 2>/dev/null || true
        }
        trap cleanup_prepare EXIT
        trap 'exit 1' HUP INT TERM
        sid=$(ubus call session create '{"timeout":300}' | jsonfilter -e '@.ubus_rpc_session')
        case "$sid" in *[!a-f0-9]*|'') fail 'invalid UCI session';; esac
        [ "${#sid}" = 32 ] || fail 'invalid UCI session length'
        printf '%s\n' "$sid" >"$state/session"
        printf '%s\n' "$section" >"$state/section"
        cp "$plan" "$state/plan"
        ubus call session grant "{\"ubus_rpc_session\":\"$sid\",\"scope\":\"uci\",\"objects\":[[\"dhcp\",\"read\"],[\"dhcp\",\"write\"]]}" >/dev/null
        ubus call uci get "{\"ubus_rpc_session\":\"$sid\",\"config\":\"dhcp\",\"section\":\"$section\"}" >"$state/before"
        "$dir/routecraft-poc-build" -uci-dhcp-plan "$state/plan" -uci-section "$section" -uci-session-file "$state/session" >"$state/request"
        ubus call uci set "$(cat "$state/request")" >/dev/null
        if [ -n "$dns_plan" ]; then
            [ -s "$dns_plan" ] || fail 'DNS plan is missing'
            dns_section=$(jsonfilter -i "$dns_plan" -e '@.section')
            case "$dns_section" in *[!a-zA-Z0-9_]*|'') fail 'invalid DNS section';; esac
            [ "$dns_section" != "$section" ] || fail 'DNS and DHCP sections must be distinct'
            printf '%s\n' "$dns_section" >"$state/dns-section"
            cp "$dns_plan" "$state/dns-plan"
            ubus call uci get "{\"ubus_rpc_session\":\"$sid\",\"config\":\"dhcp\",\"section\":\"$dns_section\"}" >"$state/dns-before"
            "$dir/routecraft-poc-build" -uci-dns-plan "$state/dns-plan" -uci-session-file "$state/session" >"$state/request"
            ubus call uci set "$(cat "$state/request")" >/dev/null
        fi
        rm -f "$state/request"
        trap - EXIT HUP INT TERM
        echo 'DHCP changes staged in an isolated UCI session; nothing applied.'
        ;;
    apply)
        [ "$#" = 1 ] || fail 'usage: apply'
        read_session
        [ ! -e "$state/applied" ] || fail 'DHCP session is already applied'
        timeout=${ROUTECRAFT_UCI_TIMEOUT:-120}
        case "$timeout" in *[!0-9]*|''|0*) fail 'invalid UCI rollback timeout';; esac
        [ "$timeout" -ge 5 ] && [ "$timeout" -le 600 ] || fail 'UCI rollback timeout must be between 5 and 600 seconds'
        # Persist the intent first, so an interrupted caller can request rollback.
        : >"$state/applied"
        if ! ubus call uci apply "{\"ubus_rpc_session\":\"$sid\",\"rollback\":true,\"timeout\":$timeout}" >/dev/null; then
            fail 'UCI apply outcome is uncertain; inspect the configuration and request rollback'
        fi
        echo "DHCP changes applied with a $timeout-second automatic rollback; confirm only after independent checks."
        ;;
    confirm)
        [ "$#" = 1 ] || fail 'usage: confirm'
        read_session
        [ -e "$state/applied" ] || fail 'DHCP session has not been applied'
        ubus call uci confirm "{\"ubus_rpc_session\":\"$sid\"}" >/dev/null || fail 'UCI confirmation failed or rollback already occurred'
        ubus call session destroy "{\"ubus_rpc_session\":\"$sid\"}" >/dev/null || fail 'could not close confirmed session'
        rm -f "$state/session" "$state/applied" "$state/before" "$state/current" "$state/plan" "$state/section" "$state/dns-plan" "$state/dns-section" "$state/dns-before" "$state/dns-current"
        rmdir "$state"
        echo 'DHCP UCI changes confirmed.'
        ;;
    rollback)
        [ "$#" = 1 ] || fail 'usage: rollback'
        read_session
        if [ -e "$state/applied" ]; then
            # Failure may mean the timer already rolled back; compare committed
            # values using a fresh read-only session before declaring success.
            ubus call uci rollback "{\"ubus_rpc_session\":\"$sid\"}" >/dev/null 2>&1 || true
            section=$(cat "$state/section")
            case "$section" in *[!a-zA-Z0-9_]*|'') fail 'invalid saved DHCP section';; esac
            verify_sid=$(ubus call session create '{"timeout":30}' | jsonfilter -e '@.ubus_rpc_session')
            case "$verify_sid" in *[!a-f0-9]*|'') fail 'invalid verification session';; esac
            [ "${#verify_sid}" = 32 ] || fail 'invalid verification session length'
            if ! ubus call session grant "{\"ubus_rpc_session\":\"$verify_sid\",\"scope\":\"uci\",\"objects\":[[\"dhcp\",\"read\"]]}" >/dev/null ||
               ! ubus call uci get "{\"ubus_rpc_session\":\"$verify_sid\",\"config\":\"dhcp\",\"section\":\"$section\"}" >"$state/current"; then
                ubus call session destroy "{\"ubus_rpc_session\":\"$verify_sid\"}" >/dev/null 2>&1 || true
                fail 'could not inspect committed DHCP state'
            fi
            if [ -e "$state/dns-plan" ]; then
                dns_section=$(cat "$state/dns-section")
                case "$dns_section" in *[!a-zA-Z0-9_]*|'') fail 'invalid saved DNS section';; esac
                if ! ubus call uci get "{\"ubus_rpc_session\":\"$verify_sid\",\"config\":\"dhcp\",\"section\":\"$dns_section\"}" >"$state/dns-current"; then
                    ubus call session destroy "{\"ubus_rpc_session\":\"$verify_sid\"}" >/dev/null 2>&1 || true
                    fail 'could not inspect committed DNS state'
                fi
            fi
            ubus call session destroy "{\"ubus_rpc_session\":\"$verify_sid\"}" >/dev/null || fail 'could not close verification session'
            "$dir/routecraft-poc-build" -verify-dhcp-plan "$state/plan" -uci-before "$state/before" -uci-current "$state/current" >/dev/null || fail 'DHCP rollback could not be confirmed'
            if [ -e "$state/dns-plan" ]; then
                "$dir/routecraft-poc-build" -verify-dns-plan "$state/dns-plan" -uci-before "$state/dns-before" -uci-current "$state/dns-current" >/dev/null || fail 'DNS rollback could not be confirmed'
            fi
        fi
        ubus call session destroy "{\"ubus_rpc_session\":\"$sid\"}" >/dev/null || fail 'could not close UCI session'
        rm -f "$state/session" "$state/applied" "$state/before" "$state/current" "$state/plan" "$state/section" "$state/dns-plan" "$state/dns-section" "$state/dns-before" "$state/dns-current"
        rmdir "$state"
        echo 'DHCP UCI session rolled back or discarded.'
        ;;
    *) fail 'usage: uci-dhcp-session.sh prepare PLAN SECTION | apply | confirm | rollback';;
esac
