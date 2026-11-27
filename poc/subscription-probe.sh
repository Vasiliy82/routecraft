#!/bin/sh
set -eu
umask 077

# Internal worker for subscription.sh. It takes a private state path and reads the URL from stdin.
die() { printf '%s\n' "$1" >&2; exit 1; }
verbose=0
if [ -t 2 ] || [ "${ROUTECRAFT_PROBE_PROGRESS:-0}" = 1 ]; then verbose=1; fi
progress() { if [ "$verbose" -eq 1 ]; then printf '%s\n' "$1" >&2; fi; }

[ "$#" -eq 1 ] || die 'Use subscription.sh for subscription commands.'
state="$1"
case "$state" in /*|--validate-url) ;; *) die 'The state directory must be an absolute path.' ;; esac
http_timeout=15 retries=2 probe_timeout=1 agent=RouteCraft/0.1.0
command -v jq >/dev/null 2>&1 || die 'jq 1.8 or later is required.'
jq -ne '"%41" | @urid == "A"' >/dev/null 2>&1 || die 'jq 1.8 or later is required.'

show_nodes() {
    jq -r '
        .selected as $selected | .nodes | to_entries[] |
        "\(.key+1) \(.value.protocol) \(.value.status)" +
        (if .value.egress_ip then " ip=" + .value.egress_ip else "" end) +
        (if .key+1 == $selected then " (first working)" else "" end)
    ' "$1"
}

origin_of() {
    printf '%s' "$1" | jq -Rser '
        def chars($allowed): all(split("")[]; . as $c | $allowed | contains($c));
        select(utf8bytelength <= 8192 and all(explode[]; . > 32 and . != 127 and . != 34 and . != 92)) |
        split("://") as $parts | $parts[0] as $scheme | select($scheme|IN("http","https")) |
        ($parts[1] // "" | split("/")[0] | split("?")[0] | split("#")[0]) as $authority |
        (if $authority|startswith("[") then
            ($authority|split("]")) as $p | select(($p|length)==2) |
            select($p[0][1:]|length>0 and chars("0123456789ABCDEFabcdef:.")) |
            select($p[1] == "" or ($p[1]|startswith(":"))) |
            [$p[0]+"]", (if $p[1]=="" then null else $p[1][1:] end)]
         else ($authority | split(":")) as $p | select(($p|length)<=2) |
            select($p[0]|length>0 and chars("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-")) | $p
         end) as $endpoint |
        ($endpoint[1] // (if $scheme == "https" then "443" else "80" end) |
            select(length > 0 and length <= 5 and chars("0123456789")) | tonumber) as $port |
        select($port > 0 and $port <= 65535) | "\($scheme)://\($endpoint[0] | ascii_downcase):\($port)"
    ' 2>/dev/null
}

url=$(head -c 8193 | sed 's/\r$//')
original_origin=$(origin_of "$url") || die 'Expected a valid HTTP or HTTPS subscription URL.'
[ "$state" != --validate-url ] || exit 0
for dependency in curl flock mkfifo sing-box; do
    command -v "$dependency" >/dev/null 2>&1 || die "Missing command: $dependency"
done

[ ! -L "$state" ] || die 'The state directory must not be a symbolic link.'
mkdir -p "$state" || die 'Cannot create state directory.'
[ "$(ls -ld "$state" | cut -c1-10)" = drwx------ ] ||
    die 'The state directory must have mode 0700.'
exec 9>"$state/lock"
flock -n 9 || die 'Another subscription update is running.'
work=$(mktemp -d /tmp/routecraft-subscription.XXXXXX) || die 'Cannot create private workspace.'
staged= child= timer= probe_pid=
stop_probe() {
    if [ -n "$probe_pid" ]; then
        kill -KILL "$probe_pid" 2>/dev/null || :
        wait "$probe_pid" 2>/dev/null || :
        probe_pid=
        exec 7<&-
    fi
}
cleanup() {
    stop_probe
    [ -z "$timer" ] || kill "$timer" 2>/dev/null || :
    [ -z "$child" ] || kill -KILL "$child" 2>/dev/null || :
    [ -z "$staged" ] || rm -f "$staged"
    rm -f "$work/"*
    rmdir "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

publish() {
    staged=$(mktemp "$state/.write.XXXXXX") || die 'Cannot stage subscription state.'
    cat "$1" > "$staged" && mv -f "$staged" "$state/$2" || die 'Cannot publish subscription state.'
    staged=
}

valid_hwid() {
    case "$1" in ''|*[!A-Za-z0-9=-]*) return 1 ;; esac
    [ "${#1}" -ge 10 ] && [ "${#1}" -le 64 ]
}

if [ ! -e "$state/hwid" ]; then
    cat /proc/sys/kernel/random/uuid > "$work/hwid" || die 'Cannot generate HWID.'
    valid_hwid "$(cat "$work/hwid")" || die 'Cannot generate HWID.'
    publish "$work/hwid" hwid
fi
hwid=$(cat "$state/hwid") || die 'Cannot read stored HWID.'
valid_hwid "$hwid" || die 'Invalid stored HWID. Use --hwid to replace it.'

http_status=000
: > "$work/body"
: > "$work/headers"
printf '{}\n' > "$work/metadata"
printf '[]\n' > "$work/nodes"

save_attempt() {
    jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg http "$http_status" --arg error "$1" \
        --rawfile headers "$work/headers" --rawfile body "$work/body" \
        --slurpfile metadata "$work/metadata" --slurpfile nodes "$work/nodes" '
        {at:$at,http_status:($http|tonumber),error:$error,headers:$headers,body:$body,
         metadata:$metadata[0],nodes:$nodes[0]}
    ' > "$work/attempt" || die 'Cannot encode attempt diagnostics.'
    publish "$work/attempt" last-attempt.json
}

fail_attempt() { save_attempt "$1"; die "$1"; }

progress 'Downloading the VPN subscription…'
os_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"\r' | head -n 1)
hop_url="$url"
send_hwid=yes
for hop in 1 2 3 4 5 6 7 8 9 10; do
    hop_origin=$(origin_of "$hop_url") || fail_attempt 'Invalid HTTP redirect.'
    case "$original_origin/$hop_origin" in https://*/http://*) fail_attempt 'HTTPS downgrade rejected.' ;; esac
    [ "$original_origin" = "$hop_origin" ] || send_hwid=no
    : > "$work/body"
    : > "$work/headers"
    {
        printf 'url = "%s"\n' "$hop_url"
        if [ "$send_hwid" = yes ]; then
            printf 'user-agent = "%s"\n' "$agent"
            printf 'header = "x-hwid: %s"\n' "$hwid"
            printf '%s\n' 'header = "x-device-os: Linux"' 'header = "x-device-model: RouteCraft"'
            printf '%s' "x-ver-os: ${os_version:-unknown}" | jq -Rsr '"header = " + @json'
            printf '\n'
        fi
    } > "$work/curl"
    if ! curl -q --config "$work/curl" --globoff --proto '=http,https' --compressed \
        --silent --header 'Accept: */*' --max-time "$http_timeout" --retry "$retries" \
        --retry-connrefused --max-filesize 4194304 \
        --dump-header "$work/headers" --output "$work/body" \
        --write-out '%{http_code}\n%{redirect_url}\n' > "$work/http" 2>/dev/null; then
        http_status=$(sed -n '1p' "$work/http")
        http_status=${http_status:-000}
        [ "$(wc -c < "$work/body")" -le 4194304 ] || : > "$work/body"
        fail_attempt 'Subscription HTTP request failed (network, timeout, TLS or response size).'
    fi
    http_status=$(sed -n '1p' "$work/http")
    [ "$(wc -c < "$work/body")" -le 4194304 ] || {
        : > "$work/body"
        fail_attempt 'Subscription response exceeds 4 MiB.'
    }
    case "$http_status" in
        301|302|303|307|308)
            [ "$hop" -lt 10 ] || fail_attempt 'Too many HTTP redirects.'
            next_url=$(sed -n '2p' "$work/http")
            case "$hop_origin/$next_url" in https://*/http://*) fail_attempt 'HTTPS downgrade rejected.' ;; esac
            hop_url="$next_url" ;;
        *) break ;;
    esac
done

parse_subscription() {
    jq -n --rawfile headers "$work/headers" --rawfile body "$work/body" '
        def payload: trim | ltrimstr("\uFEFF") | trim;
        def split_once($separator):
            index($separator) as $at |
            if $at == null then [.,null] else [.[0:$at], .[($at+($separator|length)):]] end;
        def header:
            split_once(":") | select(.[1] != null) |
            {key:(.[0]|trim|ascii_downcase),value:(.[1]|trim)};
        def recognized:
            IN("profile-title","profile-update-interval","subscription-userinfo","support-url",
               "profile-web-page-url","announce","routing","fallback-url") or
            startswith("x-hwid-") or startswith("fragmentation-");
        def b64:
            split("\n")|join("")|split("\r")|join("")|split("\t")|join("")|split(" ")|join("") |
            split("-")|join("+")|split("_")|join("/") |
            . + ("=" * ((4-length%4)%4)) | @base64d;
        def flags($meta):
            def enabled($key): any($meta[$key][]?; (ascii_downcase == "true" or . == "1"));
            if enabled("x-hwid-limit") or enabled("x-hwid-max-devices-reached") then
                "Subscription device limit reached."
            elif enabled("x-hwid-not-supported") or enabled("x-hwid-invalid") or enabled("x-hwid-error") then
                "Subscription provider rejected the HWID."
            elif any($meta["subscription-userinfo"][]? | split(";")[] | split_once("=") |
                select((.[0]|trim|ascii_downcase)=="expire" and .[1]!=null) | try (.[1]|trim|tonumber);
                . > 0 and . <= now) then "Subscription expired."
            else "" end;
        def protocol:
            ascii_downcase |
            if . == "ss" then "shadowsocks" elif . == "hy2" then "hysteria2"
            elif IN("vless","vmess","trojan","shadowsocks","hysteria2","tuic") then .
            else "unknown" end;
        def placeholder: ascii_downcase | contains("app not supported") or contains("subscription expired") or contains("device limit");
        def uuid: ascii_downcase | split("-") |
            (map(length) == [8,4,4,4,12]) and all(.[]|split("")[]; . as $c | "0123456789abcdef" | contains($c));
        def nonempty: with_entries(select(.value != null and .value != ""));
        def unescape: @urid;
        def query:
            split("&") | map(select(length>0) | split_once("=") |
                {(.[0]|split("+")|join(" ")|unescape):(.[1] // "" |split("+")|join(" ")|unescape)}) | add // {};
        def endpoint:
            (if startswith("[") then split_once("]:") | .[0] |= ltrimstr("[")
             else split_once(":") end) |
            if .[0] == "" or .[1] == null or .[1] == "" or
                (all(.[1]|split("")[]; . as $c | "0123456789" | contains($c))|not)
            then error("invalid") else {server:.[0],server_port:(.[1]|tonumber)} end;
        def transport($q):
            ($q.type // "tcp") as $type |
            if $type == "" or $type == "tcp" or $type == "raw" then
                if ($q.headerType // "none") | IN("","none") then null else error("unsupported") end
            elif $type == "ws" then
                ($q.path // "" | split("?")) as $parts |
                (($parts[1:] | join("?")) | query) as $early |
                (try (($early.ed // "0") | tonumber) catch 0) as $ed |
                {type:"ws",path:($q.path // "/"),headers:(if ($q.host // "") == "" then null else {Host:$q.host} end)}
                + (if $ed > 0 then
                    {path:($parts[0] + (if ($early|length)>1 then
                        "?" + ($early | del(.ed) | to_entries | map((.key|@uri)+"="+(.value|@uri))|join("&"))
                        else "" end)),max_early_data:$ed,early_data_header_name:"Sec-WebSocket-Protocol"}
                   else {} end) | nonempty
            elif $type == "httpupgrade" then {type:$type,path:$q.path,host:$q.host} | nonempty
            elif $type == "grpc" and (($q.mode // "gun") | IN("","gun")) then {type:$type,service_name:$q.serviceName} | nonempty
            elif $type == "http" or $type == "h2" then
                {type:"http",path:$q.path,host:($q.host // "" | split(","))} | nonempty
            elif $type == "quic" and (($q.quicSecurity // "none") | IN("","none")) and
                ($q.key // "") == "" and (($q.headerType // "none") | IN("","none")) then {type:"quic"}
            else error("unsupported") end;
        def tls($q; $security):
            if $security == "tls" or $security == "reality" then
                if ($q.pinSHA256 // $q.pin // "") != "" then error("unsupported")
                elif $security == "reality" and ($q.pbk // "") == "" then error("invalid")
                else {enabled:true,server_name:$q.sni,
                    alpn:(if ($q.alpn // "") != "" then $q.alpn | split(",") else null end),
                    utls:(if ($q.fp // "") != "" or $security == "reality" then
                        {enabled:true,fingerprint:($q.fp // "chrome")} else null end),
                    reality:(if $security == "reality" then
                        {enabled:true,public_key:$q.pbk,short_id:($q.sid // "")} else null end)} | nonempty
                end
            elif $security == "" or $security == "none" then null
            else error("unsupported") end;
        def checked:
            if (.server|tostring|ascii_downcase|IN("0.0.0.0","::","0:0:0:0:0:0:0:0")) or
                .uuid == "00000000-0000-0000-0000-000000000000" then error("placeholder")
            elif (.server|type) != "string" or .server == "" or
                 (.server_port|type) != "number" or .server_port != (.server_port|floor) or
                 .server_port < 1 or .server_port > 65535 then error("invalid")
            elif (.type|IN("vless","vmess","tuic")) and ((.uuid // "" | tostring | uuid)|not) then error("invalid")
            elif (.type|IN("trojan","hysteria2","tuic","shadowsocks")) and (.password // "") == "" then error("invalid")
            elif .type == "shadowsocks" and (.method // "") == "" then error("invalid")
            else .tag = "candidate" end;
        def uri_parts($proto):
            split_once("://")[1] | split_once("#") as $link |
            ($link[1] // "" | unescape) as $label |
            ($link[0] | split_once("?")) as $parts |
            if $proto == "vmess" and ($parts[0]|contains("@")|not) then
                ($parts[0] | unescape | b64 | fromjson) as $v |
                {name:($v.ps // $label),cfg:({type:$proto,server:$v.add,server_port:($v.port|tonumber),
                    uuid:$v.id,security:($v.scy // "auto"),alter_id:($v.aid // 0|tonumber),
                    tls:tls($v; $v.tls // ""),transport:transport($v+{type:$v.net,headerType:$v.type,serviceName:$v.path})} | nonempty)}
            else
                ($parts[0] | rtrimstr("/") |
                    if $proto == "shadowsocks" and (contains("@")|not) then b64 else . end |
                    split("@") | if length < 2 then error("invalid")
                    else {auth:(.[:-1]|join("@")),remote:.[-1]} end) as $authority |
                ($authority.remote | endpoint) as $server |
                ($authority.auth | split(":")) as $credentials |
                ($credentials[0] | unescape) as $user |
                ($credentials[1:] | join(":") | unescape) as $password |
                ($parts[1] // "" | query) as $q |
                {name:$label,cfg:($server+{type:$proto}+
                    (if $proto == "vless" then
                        if ($q.encryption // "none") != "none" then error("unsupported")
                        else {uuid:$user,flow:$q.flow} end
                    elif $proto == "vmess" then {uuid:$user,security:($q.scy // "auto")}
                    elif $proto == "tuic" then {uuid:$user,password:$password,
                        congestion_control:$q.congestion_control,udp_relay_mode:$q.udp_relay_mode}
                    elif $proto == "shadowsocks" then
                        (if ($credentials|length) == 1 then ($user | b64 | split(":")) else [$user,$password] end) as $auth |
                        ($q.plugin // "" | split(";")) as $plugin |
                        {method:$auth[0],password:($auth[1:]|join(":")),plugin:$plugin[0],plugin_opts:($plugin[1:]|join(";"))}
                    else {password:([$user,$password] | if ($credentials|length)>1 then join(":") else .[0] end),
                        obfs:(if ($q.obfs // "") != "" and $proto == "hysteria2" then
                            {type:$q.obfs,password:$q["obfs-password"]} else null end)}
                    end) + {
                        tls:(if $proto == "shadowsocks" then null else
                            tls($q; if $proto|IN("trojan","hysteria2","tuic") then $q.security // "tls"
                                    else $q.security // "" end) end),
                        transport:(if $proto|IN("vless","vmess","trojan") then transport($q) else null end)
                    } | nonempty)}
            end;
        def result($node; $parsed):
            $node + {name:($parsed.name // "")} |
            if .name | placeholder then .status = "placeholder"
            else .sing_box = ($parsed.cfg | checked) | .status = "pending" end;
        def parse_uri:
            . as $uri | ($uri | split("://")[0] | protocol) as $proto |
            ($uri | split_once("#")[1] // "" | try unescape catch "") as $label |
            (if $proto == "vmess" then
                (try ($uri | split_once("://")[1] | split_once("#")[0] |
                    split_once("?")[0] | unescape | b64 | fromjson | .ps | strings) // $label)
             else $label end) as $name |
            {uri:$uri,protocol:$proto,name:$name} as $node |
            if $proto == "unknown" then $node + {status:"unsupported"}
            else try result($node; uri_parts($proto)) catch
                ($node + {status:(if IN("unsupported","placeholder") then . else "invalid" end)}) end
            // ($node + {status:"invalid"});
        def pick($keys): with_entries(select(.key as $key | $keys | index($key) != null));
        def singbox($proto):
            . as $raw | pick(["server","server_port","uuid","security","alter_id","flow","password","method","plugin",
                "plugin_opts","packet_encoding","global_padding","authenticated_length","congestion_control","udp_relay_mode",
                "server_ports","hop_interval","up_mbps","down_mbps","network"]) + {type:$proto,tls:
                ($raw.tls | if type == "object" then
                    if has("ech") or has("certificate") or has("certificate_path") or
                        has("certificate_public_key_sha256") or has("client_certificate") or
                        has("client_certificate_path") or has("client_key") or has("client_key_path") then error("unsupported")
                    else pick(["enabled","server_name","alpn","min_version","max_version","disable_sni"]) +
                        {utls:($raw.tls.utls | if type == "object" then pick(["enabled","fingerprint"]) else null end),
                         reality:($raw.tls.reality | if type == "object" then pick(["enabled","public_key","short_id"]) else null end)} | nonempty
                    end else null end),
                transport:($raw.transport | if type == "object" then pick(["type","path","host","headers","method",
                    "service_name","max_early_data","early_data_header_name"]) else null end),
                obfs:($raw.obfs | if type == "object" then pick(["type","password","min_packet_size","max_packet_size"]) else null end)
            } | nonempty;
        def single: if type == "array" and length == 1 then .[0] else error("unsupported") end;
        def xray($proto):
            .streamSettings as $stream |
            (if $proto|IN("vless","vmess") then .settings.vnext
             elif $proto|IN("trojan","shadowsocks") then .settings.servers else error("unsupported") end | single) as $server |
            (if $proto|IN("vless","vmess") then $server.users|single else $server end) as $auth |
            ($stream.security // "") as $security |
            ($stream[($security + "Settings")] // {}) as $tls |
            ($stream.network // "tcp") as $type |
            ($stream[($type + "Settings")] // {}) as $transport |
            if ($type | IN("tcp","raw","ws","grpc","httpupgrade") | not) or $transport.multiMode == true or
                $tls.pqv != null or $tls.certificates != null or $tls.pinnedPeerCertificateChainSha256 != null or
                $tls.pinnedPeerCertificatePublicKeySha256 != null or
                ($proto == "vless" and ($auth.encryption // "none") != "none") then error("unsupported")
            else {type:$proto,server:$server.address,server_port:($server.port|tonumber),uuid:$auth.id,
                password:$auth.password,method:$auth.method,flow:$auth.flow,security:$auth.security,alter_id:$auth.alterId,
                transport:transport({type:$type,headerType:$transport.header.type,path:$transport.path,
                    host:($transport.host // $transport.headers.Host),serviceName:$transport.serviceName}),
                tls:tls({sni:$tls.serverName,fp:$tls.fingerprint,pbk:($tls.publicKey // $tls.password),
                    sid:$tls.shortId,alpn:($tls.alpn // [] | join(","))}; $security)} | nonempty end;
        def parse_objects($depth):
            if $depth > 3 then empty
            elif type == "array" then .[] | parse_objects($depth+1)
            elif type == "object" and (.outbounds | type) == "array" then .outbounds | parse_objects($depth+1)
            elif type == "object" then
                . as $raw | (($raw.type // $raw.protocol // "") | tostring | protocol) as $proto |
                {raw:$raw,protocol:$proto,name:($raw.tag|strings // "")} as $node |
                if $proto == "unknown" then $node + {status:"unsupported"}
                else try result($node; {name:$node.name,cfg:($raw |
                    if .type != null then singbox($proto) else xray($proto) end)}) catch
                    ($node + {status:(if IN("unsupported","placeholder") then . else "invalid" end)}) end
            else empty end;
        def textual($text):
            [$text | split("\n")[] | trim | select(length>0) ] |
            {fields:[.[] | ltrimstr("#") | trim | header | select(.key|recognized)],
             lines:[.[] | select(startswith("#")|not) |
                select(([header | select(.key|recognized)] | length) == 0)]};
        def content($data):
            if $data == "" then {error:"Empty subscription.",nodes:[],fields:[]}
            elif $data | startswith("<") then {error:"Received a web page instead of a subscription.",nodes:[],fields:[]}
            elif $data | (startswith("{") or startswith("[")) then
                {error:"",nodes:[$data|fromjson|parse_objects(0)],fields:[]}
            else textual($data) as $text |
                {error:"",fields:$text.fields,nodes:[$text.lines[] |
                    if contains("://") then parse_uri elif placeholder then {protocol:"unknown",status:"placeholder"}
                    else empty end]}
            end;
        ($headers | split("\n") | reduce .[] as $line ([]; if $line|startswith("HTTP/") then []
            else . + [$line|trim|header|select(.key|recognized)] end)) as $header_fields |
        ($body | payload) as $text |
        (try content($text) catch {error:"Invalid subscription JSON.",nodes:[],fields:[]}) as $plain |
        (if ($plain.nodes|length)==0 and $plain.error=="" then
            (try (textual($text).lines | join("") | b64 | payload | content(.)) catch $plain) |
            if . == $plain then . else .fields = ($plain.fields + .fields) end
         else $plain end) as $parsed |
        (reduce ($header_fields + $parsed.fields)[] as $field ({}; .[$field.key] += [$field.value])) as $metadata |
        flags($metadata) as $provider_error |
        {metadata:$metadata,nodes:$parsed.nodes,error:(
            if $provider_error != "" then $provider_error
            elif $parsed.error != "" then $parsed.error
            elif ($parsed.nodes|length)==0 then "No connections in subscription."
            else "" end)}
    ' > "$work/parsed" 2>/dev/null
}

parse_subscription || fail_attempt 'Cannot parse subscription response.'
jq '.metadata' "$work/parsed" > "$work/metadata"
jq '.nodes' "$work/parsed" > "$work/nodes"
parse_error=$(jq -r '.error' "$work/parsed")
case "$parse_error" in
    'Subscription device limit reached.'|'Subscription provider rejected the HWID.'|'Subscription expired.')
        fail_attempt "$parse_error" ;;
esac
case "$http_status" in
    200) ;;
    410) fail_attempt 'Subscription expired or removed (HTTP 410).' ;;
    *) fail_attempt "Subscription HTTP status $http_status." ;;
esac
[ -z "$parse_error" ] || fail_attempt "$parse_error"
total=$(jq -r 'length' "$work/nodes")
progress "Received $total nodes. Checking compatibility and HTTPS with DNS through each VPN."

bounded() {
    rm -f "$work/timed-out"
    "$@" </dev/null > "$work/probe-output" 2>/dev/null &
    child=$!
    (
        sleep "$probe_timeout" &
        delay=$!
        trap 'kill "$delay" 2>/dev/null || :; exit 0' TERM
        wait "$delay" || exit 0
        if kill -KILL "$child" 2>/dev/null; then : > "$work/timed-out"; fi
    ) </dev/null >/dev/null 2>&1 &
    timer=$!
    code=0
    wait "$child" 2>/dev/null || code=$?
    child=
    kill "$timer" 2>/dev/null || :
    wait "$timer" 2>/dev/null || :
    timer=
    if [ -f "$work/timed-out" ]; then return 124; fi
    return "$code"
}

egress_ip() {
    jq -ers '
        select(length == 1) | .[0].ip | strings |
        select((split(".") | length == 4 and all(.[];
            length >= 1 and length <= 3 and all(explode[]; . >= 48 and . <= 57) and
            (tonumber <= 255))))
    ' "$work/probe-output" 2>/dev/null
}

probe_https() {
    sing-box run -c "$work/probe.json" </dev/null >"$work/proxy-ready" 2>&1 &
    probe_pid=$!
    exec 7<"$work/proxy-ready"
    port=
    # Port 0 lets the kernel assign a free port, even during parallel checks.
    while IFS= read -r -t 1 line <&7; do
        case "$line" in
            *'tcp server started at 127.0.0.1:'*)
                port=${line##*127.0.0.1:}
                case "$port" in ''|*[!0-9]*) port= ;; *) break ;; esac ;;
        esac
    done
    status=probe_failed
    if [ -n "$port" ]; then
        if curl -q --noproxy '' --proxy "socks5h://127.0.0.1:$port" \
            --fail --silent --max-time "$probe_timeout" --max-filesize 1024 \
            'https://api.ipify.org?format=json' >"$work/probe-output" 2>/dev/null; then
            if public_ip=$(egress_ip); then status=working; fi
        else
            if [ "$?" -eq 28 ]; then status=probe_timeout; fi
        fi
    fi
    stop_probe
}

jq -c '.[]' "$work/nodes" > "$work/queue"
: > "$work/checked"
mkfifo "$work/proxy-ready"
index=0 selected=0
while IFS= read -r row; do
    index=$((index + 1))
    status=$(printf '%s\n' "$row" | jq -r '.status')
    public_ip=
    if [ "$verbose" -eq 1 ]; then
        heading=$(printf '%s\n' "$row" | jq -r '
            def shown_name:
                (.name // "" | strings | explode |
                    map(select(. >= 32 and (. < 127 or . >= 160) and . != 1564 and
                        (. < 8206 or . > 8207) and (. < 8232 or . > 8238) and
                        (. < 8294 or . > 8297))) | implode | trim) as $name |
                if ($name | length) > 240 or ($name | contains("://") or contains("@")) or
                    any(range(0; ($name | length)-35); . as $offset |
                        ($name[$offset:$offset+36] | split("-") | map(length)) == [8,4,4,4,12])
                then "" else $name[:80] end;
            .protocol + (shown_name | if . == "" then "" else " — " + . end)
        ')
        if [ "$status" = pending ]; then progress "[$index/$total] $heading"; fi
    fi
    if [ "$status" = pending ]; then
        printf '%s\n' "$row" | jq '
            {log:{level:"info"},
             inbounds:[{type:"mixed",tag:"probe",listen:"127.0.0.1",listen_port:0}],
             dns:{servers:[{type:"local",tag:"local-dns"},
                           {type:"https",tag:"probe-dns",server:"1.1.1.1",detour:"candidate"}]},
             outbounds:[.sing_box],route:{final:"candidate",default_domain_resolver:"local-dns",rules:[
                {domain:["api.ipify.org"],action:"resolve",server:"probe-dns",strategy:"ipv4_only",disable_cache:true},
                {domain:["api.ipify.org"],action:"route",outbound:"candidate"},
                {action:"reject"}
             ]}}
        ' > "$work/probe.json"
        if bounded sing-box check -c "$work/probe.json"; then
            probe_https
        else
            case "$?" in 124) status=check_timeout ;; *) status=sing_box_rejected ;; esac
        fi
    fi
    marker=
    if [ "$status" = working ] && [ "$selected" -eq 0 ]; then
        selected="$index"
        marker=' (first working)'
    fi
    if [ "$verbose" -eq 1 ]; then
        progress "[$index/$total] $heading: $status${public_ip:+ ip=$public_ip}$marker"
    fi
    printf '%s\n' "$row" | jq -c --arg status "$status" --arg ip "$public_ip" \
        '.status = $status | if $ip == "" then . else .egress_ip = $ip end' >> "$work/checked"
done < "$work/queue"
jq -s '.' "$work/checked" > "$work/nodes"

printf '%s' "$url" > "$work/url"
printf '%s' "$agent" > "$work/user-agent"
jq -n --argjson selected "$selected" --rawfile url "$work/url" --rawfile user_agent "$work/user-agent" \
    --slurpfile nodes "$work/nodes" --slurpfile metadata "$work/metadata" \
    '{url:$url,user_agent:$user_agent,selected:$selected,nodes:$nodes[0],metadata:$metadata[0]}' > "$work/current"
if [ "$verbose" -eq 0 ] || { [ -t 2 ] && [ ! -t 1 ]; }; then show_nodes "$work/current"; fi
[ "$selected" -gt 0 ] || fail_attempt 'No connection completed the VPN HTTPS probe.'
save_attempt ''
publish "$work/current" current.json
printf 'selected=%s (private result: current.json)\n' "$selected"
