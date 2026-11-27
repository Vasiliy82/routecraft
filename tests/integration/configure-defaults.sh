#!/bin/sh
# Exercise the wizard with isolated command stubs; no network or service changes.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/site"
cat >"$tmp/bin/id" <<'EOF'
#!/bin/sh
echo 0
EOF
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in *network.lan.device*) echo lan-test;; *network.lan.dns*) echo 198.51.100.53;; *) exit 1;; esac
EOF
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
    '-4 route show dev alternate scope link') echo '203.0.113.0/24 dev alternate';;
    '-4 route show dev lan-test scope link') echo '198.51.100.0/24 dev lan-test';;
    '-4 route show default') echo 'default via 198.51.100.1 dev lan-test';;
    'link show dev '*) exit 0;;
    *) exit 1;;
esac
EOF
cat >"$tmp/bin/tailscale" <<'EOF'
#!/bin/sh
case "$*" in
  'status --json') printf 'status';;
  'debug prefs') printf 'prefs';;
  'up '*)
    printf '%s\n' "$*" >"$MOCK_TS_CALLS"
    for arg in "$@"; do case "$arg" in --auth-key=file:*) key_file=${arg#--auth-key=file:}; [ "$(cat "$key_file")" = system-test-key ] || exit 1; printf '%s' "$key_file" >"$MOCK_TS_KEY_PATH";; esac; done;;
  *) exit 1;;
esac
EOF
cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
cat >/dev/null
case "$2" in
    '@.BackendState') printf '%s' "${MOCK_STATE:-}";;
    '@.ControlURL') printf '%s' "${MOCK_CONTROL:-}";;
    '@.ExitNodeStatus.TailscaleIPs[*]') printf '%s\n' "${MOCK_EXIT:-}";;
    '@.Peer[@.ExitNodeOption=true].ExitNodeOption') printf '%s\n' "${MOCK_CANDIDATES:-}";;
    '@.Peer[@.ExitNodeOption=true].TailscaleIPs[*]') printf '%s\n' "${MOCK_CANDIDATE_IPS:-}";;
    *) exit 1;;
esac
EOF
cat >"$tmp/site/routecraft-build" <<'EOF'
#!/bin/sh
case "$1" in
  -list-interfaces) printf 'lan-test\nalternate\n';;
  -check-interface) case "$2" in lan-test|alternate) exit 0;; *) exit 1;; esac;;
  -list-exit-nodes)
    [ "${MOCK_NODES:-0}" = 1 ] || exit 1
    if [ "$#" -gt 2 ] && [ -n "$4" ]; then [ "$4" = 100.64.0.42 ]; else printf '[{"address":"100.64.0.42","name":"fixture"}]\n'; fi;;
  *) exit 0;;
esac
EOF
cat >"$tmp/site/start.sh" <<'EOF'
#!/bin/sh
[ "$(cat "$ROUTECRAFT_DIR/.update.lock/owner")" = "$ROUTECRAFT_LOCK_OWNER" ] || exit 1
printf '%s' "$ROUTECRAFT_INITIAL_OPTIONAL_VPN" >"$ROUTECRAFT_DIR/initial-mode"
printf '%s\n' candidate >"$ROUTECRAFT_DIR/sing-box.candidate.json"
exit 0
EOF
cat >"$tmp/site/install.sh" <<'EOF'
#!/bin/sh
[ "$1" = --activate ]
EOF
chmod +x "$tmp/bin/"* "$tmp/site/routecraft-build"
PATH="$tmp/bin:$PATH"; export PATH
ROUTECRAFT_DIR="$tmp/site"; export ROUTECRAFT_DIR
ROUTECRAFT_SECRET_DIR="$tmp/secrets"; export ROUTECRAFT_SECRET_DIR
printf 'old-subscription\n' >"$tmp/site/subscription.url"
printf 'old-key\n' >"$tmp/site/headscale.key"
printf 'existing\n' >"$tmp/site/site.env"

MOCK_STATE=Running MOCK_CONTROL=https://control.example.invalid MOCK_EXIT='fd7a:115c:a1e0::1/128 100.64.0.42/32'
export MOCK_STATE MOCK_CONTROL MOCK_EXIT
printf 'n\n\nalternate\n\n\n\n\nhttps://example.invalid/sub\nkey\nn\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"
[ "$(cat "$tmp/site/subscription.url")" = old-subscription ]
[ "$(cat "$tmp/site/headscale.key")" = old-key ]
sha256sum -c "$tmp/site/candidate.sha256" >/dev/null
printf 'modified\n' >>"$tmp/site/headscale.candidate.key"
if sha256sum -c "$tmp/site/candidate.sha256" >/dev/null 2>&1; then echo 'modified candidate secret was accepted' >&2; exit 1; fi
grep -q 'ROUTECRAFT_LAN_INTERFACE=alternate' "$tmp/site/site.candidate.env"
grep -q 'ROUTECRAFT_LAN_SUBNET=203.0.113.0/24' "$tmp/site/site.candidate.env"
grep -q 'ROUTECRAFT_DNS_UPSTREAM=198.51.100.53' "$tmp/site/site.candidate.env"
grep -q 'ROUTECRAFT_HEADSCALE_URL=https://control.example.invalid' "$tmp/site/site.candidate.env"
grep -q 'ROUTECRAFT_EXIT_NODE=100.64.0.42' "$tmp/site/site.candidate.env"
printf 'n\n\nmissing\nalternate\n\n\n\n\nhttps://example.invalid/sub\nkey\nn\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"
grep -q 'cannot be selected' "$tmp/err"
grep -q 'ROUTECRAFT_LAN_INTERFACE=alternate' "$tmp/site/site.candidate.env"
printf 'y\n\n\n\n\n\n\nhttps://example.invalid/sub\nkey\nn\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"
grep -q 'ROUTECRAFT_DISABLE_REBIND=1' "$tmp/site/site.candidate.env"
[ "$(cat "$tmp/site/subscription.url")" = old-subscription ]

MOCK_EXIT= MOCK_CANDIDATES=true MOCK_CANDIDATE_IPS='fd00::2 100.64.0.43'
export MOCK_EXIT MOCK_CANDIDATES MOCK_CANDIDATE_IPS
printf 'n\n\n\n\n\n\n\nhttps://example.invalid/sub\nkey\nn\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"
grep -q 'ROUTECRAFT_EXIT_NODE=100.64.0.43' "$tmp/site/site.candidate.env"
grep -q 'Tailscale Exit Node name or IP \[100.64.0.43\]' "$tmp/err"

MOCK_CANDIDATES='true
true'
export MOCK_CANDIDATES
printf 'n\n\n\n\n\n\nexit.example\nhttps://example.invalid/sub\nkey\nn\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"
grep -q 'Multiple Tailscale Exit Nodes are available' "$tmp/err"
grep -q 'ROUTECRAFT_EXIT_NODE=exit.example' "$tmp/site/site.candidate.env"

MOCK_STATE=Stopped
export MOCK_STATE
printf 'n\n\n\n\n\n\nexit.example\nhttps://example.invalid/sub\nkey\nn\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"
grep -q 'ROUTECRAFT_HEADSCALE_URL=https://controlplane.tailscale.com' "$tmp/site/site.candidate.env"
grep -q 'ROUTECRAFT_EXIT_NODE=exit.example' "$tmp/site/site.candidate.env"
grep -q 'Tailscale Exit Node name or IP: ' "$tmp/err"

if printf 'n\n\n\n\n\n\n\nhttps://example.invalid/sub\nkey\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"; then
    echo 'Expected missing exit node to fail' >&2; exit 1
fi
grep -q 'Invalid Exit Node' "$tmp/err"

if printf 'n\n\n\n\n\nhttp://wrong.invalid\nexit.example\nhttps://example.invalid/sub\nkey\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"; then
    echo 'Expected invalid control URL to fail' >&2; exit 1
fi
grep -q 'Control URL must use HTTPS' "$tmp/err"

rm "$tmp/site/site.env"
printf 'n\n\n\n\n\n\n\nn\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"
[ "$(cat "$tmp/site/initial-mode")" = 1 ]
[ ! -s "$tmp/site/subscription.candidate.url" ] || [ "$(cat "$tmp/site/subscription.candidate.url")" = '' ]
MOCK_NODES=1 MOCK_STATE=Running; export MOCK_NODES MOCK_STATE
printf 'n\n\n\n\n\ny\n100.64.0.42\n\nkey\n\nn\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"
grep -q 'ROUTECRAFT_EXIT_NODE=100.64.0.42' "$tmp/site/site.candidate.env"
[ "$(cat "$tmp/site/headscale.candidate.key")" = key ]
printf 'n\n\n\n\n\nn\n\nn\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"
grep -qx 'ROUTECRAFT_EXIT_NODE=' "$tmp/site/site.candidate.env"
[ "$(cat "$tmp/site/headscale.candidate.key")" = '' ]
mv "$tmp/bin/tailscale" "$tmp/tailscale-stub"
old_path=$PATH
PATH="$tmp/bin:/usr/bin"; export PATH
MOCK_NODES=0; export MOCK_NODES
printf 'n\n\n\n\n\nn\n\nn\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"
grep -q 'Tailscale is not installed' "$tmp/err"
grep -qx 'ROUTECRAFT_EXIT_NODE=' "$tmp/site/site.candidate.env"
cat >"$tmp/bin/apk" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MOCK_APK_LOG"
case "$*" in update) exit 0;; 'add tailscale') cp "$MOCK_TS_FIXTURE" "$MOCK_BIN/tailscale";; *) exit 1;; esac
EOF
chmod +x "$tmp/bin/apk"
MOCK_APK_LOG="$tmp/apk-calls" MOCK_TS_FIXTURE="$tmp/tailscale-stub" MOCK_BIN="$tmp/bin"
export MOCK_APK_LOG MOCK_TS_FIXTURE MOCK_BIN
printf 'n\n\n\n\n\ny\nn\n\nn\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"
grep -q '^add tailscale$' "$tmp/apk-calls"
grep -qx 'ROUTECRAFT_EXIT_NODE=' "$tmp/site/site.candidate.env"
rm "$tmp/bin/tailscale"
cat >"$tmp/ts-init" <<'EOF'
#!/bin/sh
case "$1" in enable|start) exit 0;; *) exit 1;; esac
EOF
chmod +x "$tmp/ts-init"
ROUTECRAFT_TS_INIT="$tmp/ts-init" MOCK_TS_CALLS="$tmp/ts-calls" MOCK_TS_KEY_PATH="$tmp/ts-key-path"
export ROUTECRAFT_TS_INIT MOCK_TS_CALLS MOCK_TS_KEY_PATH
printf 'n\n\n\n\n\ny\ny\n\nsystem-test-key\n\nn\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"
grep -q -- '--accept-dns=false' "$tmp/ts-calls"
grep -q -- '--accept-routes=false' "$tmp/ts-calls"
if grep -q system-test-key "$tmp/ts-calls"; then echo 'system key exposed in arguments' >&2; exit 1; fi
[ ! -e "$(cat "$tmp/ts-key-path")" ]
unset ROUTECRAFT_TS_INIT
rm "$tmp/bin/apk" "$tmp/bin/tailscale"
PATH=$old_path; export PATH
mv "$tmp/tailscale-stub" "$tmp/bin/tailscale"
printf 'active\n' >"$tmp/site/site.env"
if printf 'n\n\n\n\n\n\nexit.example\n\nkey\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"; then
    echo 'Expected an existing installation to reject an empty subscription' >&2; exit 1
fi
grep -q 'existing installation requires a subscription' "$tmp/err"

mkdir "$ROUTECRAFT_SECRET_DIR"
printf 'https://example.invalid/file-token\n' >"$ROUTECRAFT_SECRET_DIR/vless-subscription-url"
printf 'file-test-key\r\n' >"$ROUTECRAFT_SECRET_DIR/tailscale-pre-auth-key"
printf '%s\n' n alternate '' '' '' '' exit.example n |
    sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"
grep -qx 'ROUTECRAFT_WAN_INTERFACE=alternate' "$tmp/site/site.candidate.env"
grep -qx 'ROUTECRAFT_LAN_INTERFACE=lan-test' "$tmp/site/site.candidate.env"
grep -qx 'https://example.invalid/file-token' "$tmp/site/subscription.candidate.url"
grep -qx 'file-test-key' "$tmp/site/headscale.candidate.key"
grep -Fq "$ROUTECRAFT_SECRET_DIR/vless-subscription-url" "$tmp/out"
grep -Fq "$ROUTECRAFT_SECRET_DIR/tailscale-pre-auth-key" "$tmp/out"
if grep -Eq 'file-token|file-test-key' "$tmp/out" "$tmp/err"; then
    echo 'file-provided secret was printed' >&2
    exit 1
fi
printf 'unexpected\nextra\n' >"$ROUTECRAFT_SECRET_DIR/tailscale-pre-auth-key"
if printf '%s\n' n '' '' '' '' '' exit.example n | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"; then
    echo 'malformed secret file was accepted' >&2
    exit 1
fi
grep -Fq 'expected one nonempty value' "$tmp/err"
printf 'file-test-key\n' >"$ROUTECRAFT_SECRET_DIR/tailscale-pre-auth-key"
printf '%s\n' '{"endpoints":[{"type":"tailscale","tag":"tailscale-exit","exit_node":"100.64.0.44"}]}' >"$tmp/site/sing-box.json"
printf '%s\n' n '' '' '' '' '' '' n | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"
grep -Fq 'Tailscale Exit Node name or IP [100.64.0.44]' "$tmp/err"
grep -qx 'ROUTECRAFT_EXIT_NODE=100.64.0.44' "$tmp/site/site.candidate.env"
echo 'configure-defaults: passed'
