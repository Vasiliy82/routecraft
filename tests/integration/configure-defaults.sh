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
case "$*" in 'status --json') printf 'status';; 'debug prefs') printf 'prefs';; *) exit 1;; esac
EOF
cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
cat >/dev/null
case "$2" in
    '@.BackendState') printf '%s' "${MOCK_STATE:-}";;
    '@.ControlURL') printf '%s' "${MOCK_CONTROL:-}";;
    '@.ExitNodeStatus.TailscaleIPs[*]') printf '%s\n' "${MOCK_EXIT:-}";;
    *) exit 1;;
esac
EOF
cat >"$tmp/site/routecraft-poc-build" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/site/start.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/"* "$tmp/site/routecraft-poc-build"
PATH="$tmp/bin:$PATH"; export PATH
ROUTECRAFT_POC_DIR="$tmp/site"; export ROUTECRAFT_POC_DIR

MOCK_STATE=Running MOCK_CONTROL=https://control.example.invalid MOCK_EXIT='fd7a:115c:a1e0::1/128 100.64.0.42/32'
export MOCK_STATE MOCK_CONTROL MOCK_EXIT
printf 'alternate\n\n\n\n\nhttps://example.invalid/sub\nkey\nn\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"
grep -q 'ROUTECRAFT_LAN_INTERFACE=alternate' "$tmp/site/site.candidate.env"
grep -q 'ROUTECRAFT_LAN_SUBNET=203.0.113.0/24' "$tmp/site/site.candidate.env"
grep -q 'ROUTECRAFT_DNS_UPSTREAM=198.51.100.53' "$tmp/site/site.candidate.env"
grep -q 'ROUTECRAFT_HEADSCALE_URL=https://control.example.invalid' "$tmp/site/site.candidate.env"
grep -q 'ROUTECRAFT_EXIT_NODE=100.64.0.42' "$tmp/site/site.candidate.env"

MOCK_STATE=Stopped
export MOCK_STATE
printf '\n\n\n\nexit.example\nhttps://example.invalid/sub\nkey\nn\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"
grep -q 'ROUTECRAFT_HEADSCALE_URL=https://controlplane.tailscale.com' "$tmp/site/site.candidate.env"
grep -q 'ROUTECRAFT_EXIT_NODE=exit.example' "$tmp/site/site.candidate.env"
grep -q 'Tailscale Exit Node name or IP: ' "$tmp/err"

if printf '\n\n\n\n\nhttps://example.invalid/sub\nkey\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"; then
    echo 'Expected missing exit node to fail' >&2; exit 1
fi
grep -q 'Invalid Exit Node' "$tmp/err"

if printf '\n\n\nhttp://wrong.invalid\nexit.example\nhttps://example.invalid/sub\nkey\n' | sh "$repo/poc/configure.sh" >"$tmp/out" 2>"$tmp/err"; then
    echo 'Expected invalid control URL to fail' >&2; exit 1
fi
grep -q 'Control URL must use HTTPS' "$tmp/err"
echo 'configure-defaults: passed'
