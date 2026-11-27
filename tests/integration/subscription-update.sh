#!/bin/sh
set -eu
umask 077

script=${1:-poc/subscription.sh}
work=$(mktemp -d /tmp/routecraft-subscription-update-test.XXXXXX)
trap 'rm -rf "$work"' EXIT
export ROUTECRAFT_DIR="$work/config"
export ROUTECRAFT_SERVICE="$work/service"
export UPDATE_FIXTURE="$work"
export PATH="$work/bin:$PATH"
mkdir "$ROUTECRAFT_DIR" "$work/bin"
cp "$script" "$work/subscription.sh"

cat >"$work/subscription-poc.sh" <<'EOF'
#!/bin/sh
set -eu
if [ "$1" = --validate-url ]; then
    [ "$(cat)" = 'https://subscription.example/test' ]
    exit
fi
[ "$1" = --state-dir ] && [ "$3" = --probe-timeout ] && [ "$4" = 1 ] &&
    [ "$5" = --require-egress-ip ] && [ "$6" = --url-stdin ]
[ "$(cat)" = 'https://subscription.example/test' ]
[ ! -f "$UPDATE_FIXTURE/probe-fails" ] || exit 1
cp "$UPDATE_FIXTURE/chosen.json" "$2/current.json"
EOF
cat >"$work/service" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = restart ] || exit 0
printf '%s\n' restart >>"$UPDATE_FIXTURE/restarts"
if [ -f "$UPDATE_FIXTURE/restart-fails" ]; then
    rm "$UPDATE_FIXTURE/restart-fails"
    exit 1
fi
EOF
cat >"$work/bin/sing-box" <<'EOF'
#!/bin/sh
test ! -f "$UPDATE_FIXTURE/config-fails"
EOF
cat >"$work/bin/curl" <<'EOF'
#!/bin/sh
set -eu
[ "$5" = socks5h://127.0.0.1:1081 ]
printf '%s\n' '{"ip":"192.0.2.9"}'
EOF
chmod +x "$work/service" "$work/bin/sing-box" "$work/bin/curl"

cfg="$ROUTECRAFT_DIR/sing-box.json"
cat >"$cfg" <<'EOF'
{
  "inbounds":[{"type":"mixed","tag":"test-vless","listen":"127.0.0.1","listen_port":1081}],
  "outbounds":[{"type":"direct","tag":"direct"},{"type":"vless","tag":"sub-a","domain_resolver":"bootstrap"},
    {"type":"vless","tag":"sub-b"},{"type":"selector","tag":"vpn-sub","outbounds":["sub-a","sub-b"],"default":"sub-a"}],
  "endpoints":[{"type":"tailscale","tag":"tailscale-exit"}],
  "route":{"rules":[{"inbound":["test-vless"],"outbound":"vpn-sub"}]},
  "dns":{"servers":[{"tag":"bootstrap"},{"type":"https","detour":"vpn-sub"}]}
}
EOF
cat >"$work/chosen.json" <<'EOF'
{"selected":1,"nodes":[{"status":"working","protocol":"hysteria2","name":"Нидерланды","uri":"fixture","egress_ip":"192.0.2.9",
 "sing_box":{"type":"hysteria2","tag":"candidate","server":"chosen.example","server_port":443,"password":"fixture","tls":{"enabled":true}}}]}
EOF
run() { sh "$work/subscription.sh" "$@"; }
run set url https://subscription.example/test
test "$(run get url)" = https://subscription.example/test
run set hwid fixture-device
test "$(run get hwid)" = fixture-device
cp "$cfg" "$work/initial"
run check
cmp "$cfg" "$work/initial"
test ! -f "$work/restarts"
run update >"$work/stdout"
grep -qx 'VPN outbound updated. Live IP: 192.0.2.9' "$work/stdout"
jq -es '.[0].route==.[1].route and .[0].dns==.[1].dns and .[0].endpoints==.[1].endpoints and
    (.[1].outbounds|map(.tag)) == ["direct","vpn-sub"] and
    .[1].outbounds[1].domain_resolver == "bootstrap"' "$work/initial" "$cfg" >/dev/null
run get selected >"$work/applied"
jq -e '.name == "Нидерланды"' "$work/applied" >/dev/null
cmp "$work/applied" "$ROUTECRAFT_DIR/subscription/selected.json"
cp "$cfg" "$work/working"
run update >"$work/stdout"
grep -qx 'VPN outbound unchanged. Restart not needed.' "$work/stdout"
cmp "$cfg" "$work/working"
test "$(wc -l <"$work/restarts")" -eq 1
jq '.nodes[0].name = "Германия"' "$work/chosen.json" >"$work/new.json"
mv "$work/new.json" "$work/chosen.json"
run update >"$work/stdout"
grep -qx 'VPN outbound unchanged. Restart not needed.' "$work/stdout"
cmp "$cfg" "$work/working"
test "$(wc -l <"$work/restarts")" -eq 1
run get selected >"$work/applied"
jq -e '.name == "Германия"' "$work/applied" >/dev/null

jq '.nodes[0].sing_box.server="changed.example"' "$work/chosen.json" >"$work/new.json"
mv "$work/new.json" "$work/chosen.json"
for failure in probe-fails config-fails restart-fails; do
    : >"$work/$failure"
    if run update >"$work/stdout" 2>"$work/stderr"; then exit 1; fi
    cmp "$cfg" "$work/working"
    cmp "$work/applied" "$ROUTECRAFT_DIR/subscription/selected.json"
    test ! -e "$ROUTECRAFT_DIR/.update.lock"
    rm -f "$work/$failure"
done
grep -qx 'Previous configuration restored and RouteCraft restarted.' "$work/stderr"
test "$(wc -l <"$work/restarts")" -eq 3
mkdir "$ROUTECRAFT_DIR/.update.lock"
if run update >/dev/null 2>&1; then exit 1; fi
cmp "$cfg" "$work/working"
test "$(wc -l <"$work/restarts")" -eq 3
printf '%s\n' 'subscription-update: settings, check, migration, no-op, shared lock and rollback passed'
