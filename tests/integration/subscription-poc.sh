#!/bin/sh
set -eu
umask 077

# Run on OpenWrt where the standalone PoC's dependencies are installed.
script=${1:-poc/subscription-poc.sh}
work=$(mktemp -d /tmp/routecraft-subscription-test.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
export POCTEST="$work"
export PATH="$work/bin:$PATH"

cat > "$work/bin/curl" <<'CURL'
#!/bin/sh
set -eu
while [ "$#" -gt 0 ]; do
    case "$1" in
        --config) config="$2"; shift ;;
        --dump-header) headers="$2"; shift ;;
        --output) body="$2"; shift ;;
    esac
    shift
done
case "$(sed -n '1p' "$config")" in
    'url = "https://origin.example/sub"')
        id=$(sed -n 's/^header = "x-hwid: \(.*\)"$/\1/p' "$config")
        test -n "$id" && grep -qx 'user-agent = "RouteCraft/0.1.0"' "$config"
        if [ -f "$POCTEST/expected-id" ]; then
            [ "$id" = "$(cat "$POCTEST/expected-id")" ]
        else
            printf '%s' "$id" > "$POCTEST/expected-id"
        fi
        printf 'HTTP/1.1 302 Moved\r\n\r\n' > "$headers"
        printf '302\nhttps://origin.example/second\n' ;;
    'url = "https://origin.example/second"')
        grep -q 'x-hwid:' "$config"
        printf '302\nhttps://cdn.example/format\n' ;;
    'url = "https://cdn.example/format"')
        [ "$(wc -l < "$config")" -eq 1 ]
        if [ -e "$POCTEST/deny" ]; then
            printf 'HTTP/2 404\r\nx-hwid-max-devices-reached: true\r\n\r\n' > "$headers"
            printf '404\n\n'
        else
            printf 'HTTP/2 200\r\nx-provider-extra: private-fixture-marker\r\nprofile-title: Test\r\n\r\n' > "$headers"
            cat "$POCTEST/fixture" > "$body"
            printf '200\n\n'
        fi ;;
    *) exit 1 ;;
esac
CURL

cat > "$work/bin/sing-box" <<'BOX'
#!/bin/sh
set -eu
case "$1" in
    check) [ "$(jq -r '.route.final' "$3")" = candidate ]; exit ;;
    tools)
        [ "$5" = -o ] && [ "$6" = candidate ]
        server=$(jq -r '.outbounds[0].server' "$4")
        case "$7" in
            https://api.ipify.org*)
                if [ "$server" = "no-egress.example" ]; then
                    printf '%s\n' '{"ip":"999.1.1.1"}'
                else
                    printf '%s\n' '{"ip":"192.0.2.1"}'
                fi
                exit ;;
        esac
        [ "$server" != unreachable.example ] || exit 1
        printf '\000\000\201\200\000\001\000\001\000\000\000\000\007example\003com\000\000\001\000\001\300\014\000\001\000\001\000\000\000\042\000\004\300\000\002\001' ;;
    *) exit 1 ;;
esac
BOX
chmod +x "$work/bin/curl" "$work/bin/sing-box"

id=11111111-2222-4333-8444-555555555555
vmess=$(printf '%s' "{\"add\":\"vmess.example\",\"port\":\"443\",\"id\":\"$id\",\"net\":\"ws\",\"path\":\"/vpn\",\"tls\":\"tls\",\"ps\":\"Проверка\"}" |
    jq -Rrs '@base64')
jq -Rrs '@base64 | split("+")|join("-")|split("/")|join("_")|split("=")|join("")' > "$work/fixture" <<EOF
#announce: Проверка
#routing: diagnostic-only
vless://$id@unreachable.example:443?security=tls&type=ws
vless://$id@no-egress.example:443?security=tls&type=ws
vless://$id@first.example:443?security=tls&type=grpc&serviceName=test#%D0%A0%D0%B0%D1%84
vless://$id@later.example:443?security=tls&type=ws&extra=%7B%22a%22%3Atrue%7D
vless://$id@xhttp.example:443?type=xhttp
vless://00000000-0000-0000-0000-000000000000@0.0.0.0:443#App%20not%20supported
trojan://p%3Aa@trojan.example:443
ss://YWVzLTEyOC1nY206YWJj@ss.example:443
hysteria2://pass@hy.example:443?obfs=salamander&obfs-password=secret
tuic://$id:pass@tuic.example:443?congestion_control=bbr
vmess://$vmess
EOF

sh "$script" --state-dir "$work/state" --require-egress-ip https://origin.example/sub > "$work/run"
grep -qx 'selected=3 (private result: current.json)' "$work/run"
grep -qx '3 vless working ip=192.0.2.1 (first working)' "$work/run"
grep -qx '1 vless probe_failed ip=192.0.2.1' "$work/run"
! grep -q "$id\|private-fixture-marker" "$work/run"
jq -e '
    .selected == 3 and
    (.nodes | map(.status)) == ["probe_failed","egress_failed","working","working","unsupported","placeholder","working","working","working","working","working"] and
    .nodes[2].name == "Раф" and .nodes[6].sing_box.password == "p:a" and
    .nodes[10].name == "Проверка" and .nodes[10].sing_box.transport.type == "ws" and
    .metadata.announce == ["Проверка"] and .metadata.routing == ["diagnostic-only"]
' "$work/state/current.json" >/dev/null
jq -e '.headers | contains("private-fixture-marker")' "$work/state/last-attempt.json" >/dev/null
cp "$work/state/current.json" "$work/kept"
: > "$work/deny"
if sh "$script" --state-dir "$work/state" > "$work/error" 2>&1; then
    printf '%s\n' 'Expected the refresh to fail.' >&2
    exit 1
fi
cmp "$work/kept" "$work/state/current.json"
grep -qx 'Subscription device limit reached.' "$work/error"

rm -f "$work/deny"
cat > "$work/fixture" <<EOF
[
  {"route":{"final":"direct"},"outbounds":[
    {"type":"trojan","server":"first.example","server_port":443,"password":"test","detour":"direct",
     "tls":{"enabled":true,"insecure":true}},
    {"type":"direct"}
  ]},
  {"outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"xray.example","port":443,
    "users":[{"id":"$id","encryption":"none"}]}]},
    "streamSettings":{"network":"xhttp","xhttpSettings":{"extra":{"anything":true}}}}]}
]
EOF
sh "$script" --state-dir "$work/state" > "$work/run"
jq -e '
    .selected == 1 and (.nodes | map(.status)) == ["working","unsupported","unsupported"] and
    .nodes[0].sing_box.tls == {enabled:true} and .nodes[0].sing_box.detour == null and
    .nodes[2].raw.streamSettings.xhttpSettings.extra.anything == true
' "$work/state/current.json" >/dev/null
printf '%s\n' 'subscription-poc: URI and JSON formats, selection, redaction, redirects, HWID, metadata and rollback passed'
