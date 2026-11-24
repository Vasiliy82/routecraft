#!/bin/sh
# Exercise session lifecycle with fake ubus; no UCI changes are made.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/site/.update.lock"
printf '%s\n' "$$" >"$tmp/site/.update.lock/owner"
cat >"$tmp/bin/ubus" <<'EOF'
#!/bin/sh
printf '%s\n' "$1 $2 $3" >>"$MOCK_CALLS"
case "$1 $2 $3" in 'call session create') printf '{}\n';; esac
if [ "$1 $2 $3" = 'call uci apply' ] && [ "${MOCK_APPLY_FAIL:-0}" = 1 ]; then exit 1; fi
exit 0
EOF
cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
case "$*" in *'@.section'*) printf 'dns_main\n';; *) cat >/dev/null; printf '0123456789abcdef0123456789abcdef\n';; esac
EOF
cat >"$tmp/site/routecraft-build" <<'EOF'
#!/bin/sh
if [ "$1" = -verify-dhcp-plan ]; then [ "${MOCK_VERIFY_FAIL:-0}" != 1 ]; exit $?; fi
if [ "$1" = -verify-dns-plan ]; then [ "${MOCK_DNS_VERIFY_FAIL:-0}" != 1 ]; exit $?; fi
printf '{"config":"dhcp","section":"lan","values":{"ignore":"1"}}\n'
EOF
chmod +x "$tmp/bin/"* "$tmp/site/routecraft-build"
PATH="$tmp/bin:$PATH" ROUTECRAFT_DIR="$tmp/site" MOCK_CALLS="$tmp/calls"
export PATH ROUTECRAFT_DIR MOCK_CALLS
printf '{}\n' >"$tmp/plan"
sh "$repo/poc/uci-dhcp-session.sh" prepare "$tmp/plan" lan >"$tmp/out"
[ -s "$tmp/site/.uci-dhcp-session/session" ]
if grep -q '^call uci apply' "$tmp/calls"; then echo 'prepare applied configuration' >&2; exit 1; fi
sh "$repo/poc/uci-dhcp-session.sh" apply >"$tmp/out"
[ -e "$tmp/site/.uci-dhcp-session/applied" ]
sh "$repo/poc/uci-dhcp-session.sh" rollback >"$tmp/out"
[ ! -e "$tmp/site/.uci-dhcp-session" ]
grep -q '^call uci rollback' "$tmp/calls"
sh "$repo/poc/uci-dhcp-session.sh" prepare "$tmp/plan" lan >"$tmp/out"
sh "$repo/poc/uci-dhcp-session.sh" apply >"$tmp/out"
sh "$repo/poc/uci-dhcp-session.sh" confirm >"$tmp/out"
[ ! -e "$tmp/site/.uci-dhcp-session" ]
grep -q '^call uci confirm' "$tmp/calls"
sh "$repo/poc/uci-dhcp-session.sh" prepare "$tmp/plan" lan >"$tmp/out"
MOCK_APPLY_FAIL=1; export MOCK_APPLY_FAIL
if sh "$repo/poc/uci-dhcp-session.sh" apply >"$tmp/out" 2>"$tmp/err"; then echo 'expected uncertain apply failure' >&2; exit 1; fi
[ -e "$tmp/site/.uci-dhcp-session/applied" ]
MOCK_APPLY_FAIL=0; export MOCK_APPLY_FAIL
MOCK_VERIFY_FAIL=1; export MOCK_VERIFY_FAIL
if sh "$repo/poc/uci-dhcp-session.sh" rollback >"$tmp/out" 2>"$tmp/err"; then echo 'unverified rollback was accepted' >&2; exit 1; fi
[ -e "$tmp/site/.uci-dhcp-session/applied" ]
MOCK_VERIFY_FAIL=0; export MOCK_VERIFY_FAIL
sh "$repo/poc/uci-dhcp-session.sh" rollback >"$tmp/out"
printf '{"section":"dns_main"}\n' >"$tmp/dns-plan"
sh "$repo/poc/uci-dhcp-session.sh" prepare "$tmp/plan" lan "$tmp/dns-plan" >"$tmp/out"
[ -s "$tmp/site/.uci-dhcp-session/dns-plan" ]
sh "$repo/poc/uci-dhcp-session.sh" apply >"$tmp/out"
MOCK_DNS_VERIFY_FAIL=1; export MOCK_DNS_VERIFY_FAIL
if sh "$repo/poc/uci-dhcp-session.sh" rollback >"$tmp/out" 2>"$tmp/err"; then echo 'unverified DNS rollback was accepted' >&2; exit 1; fi
[ -e "$tmp/site/.uci-dhcp-session/applied" ]
MOCK_DNS_VERIFY_FAIL=0; export MOCK_DNS_VERIFY_FAIL
sh "$repo/poc/uci-dhcp-session.sh" rollback >"$tmp/out"
[ ! -e "$tmp/site/.uci-dhcp-session" ]
rm "$tmp/site/.update.lock/owner"
if sh "$repo/poc/uci-dhcp-session.sh" prepare "$tmp/plan" lan >"$tmp/out" 2>"$tmp/err"; then echo 'missing lock was accepted' >&2; exit 1; fi
echo 'uci-dhcp-session: passed'
