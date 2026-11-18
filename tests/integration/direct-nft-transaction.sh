#!/bin/sh
# Verify NAT replacement is submitted in a single nft transaction.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin"
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/bin/sysctl" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_DIR/calls"
case "$*" in
  'list table inet routecraft_poc') exit 0;;
  '-f -') cat >"$TEST_DIR/transaction"; [ "${FAIL_NFT:-0}" != 1 ];;
  *) exit 1;;
esac
EOF
chmod +x "$tmp/bin/"*
PATH="$tmp/bin:$PATH" TEST_DIR="$tmp" ROUTECRAFT_LAN_INTERFACE=lan0 ROUTECRAFT_LAN_SUBNET=192.0.2.0/24
export PATH TEST_DIR ROUTECRAFT_LAN_INTERFACE ROUTECRAFT_LAN_SUBNET
FAIL_NFT=1; export FAIL_NFT
if sh "$repo/poc/direct-gateway.sh" >"$tmp/out" 2>"$tmp/err"; then echo 'expected failure' >&2; exit 1; fi
[ "$(grep -c '^delete table inet routecraft_poc$' "$tmp/transaction")" = 1 ]
grep -q '^table inet routecraft_poc' "$tmp/transaction"
if grep -q '^delete table' "$tmp/calls"; then echo 'table deleted outside transaction' >&2; exit 1; fi
echo 'direct-nft-transaction: passed'
