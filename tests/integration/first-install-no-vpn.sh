#!/bin/sh
# Real first-install candidate test; no activation or network configuration.
set -eu
[ "${1:-}" = --isolated ] && [ "$#" = 3 ] || { echo 'Usage: sh first-install-no-vpn.sh --isolated BUILDER SING_BOX' >&2; exit 2; }
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
[ "$(id -u)" = 0 ] || { echo 'This test requires root on an isolated OpenWrt VM.' >&2; exit 1; }
[ -x "$2" ] && [ -x "$3" ] || { echo 'Builder and sing-box must be executable.' >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "$tmp/site" "$tmp/bin"
cp "$2" "$tmp/site/routecraft-build"
cp "$repo/poc/configure.sh" "$repo/poc/start.sh" "$repo/poc/policy.yaml" "$tmp/site/"
ln -s "$3" "$tmp/bin/sing-box"
cat >"$tmp/site/install.sh" <<'EOF'
#!/bin/sh
[ "$1" = --activate ]
EOF
cat >"$tmp/bin/tailscale" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 700 "$tmp/bin/tailscale" "$tmp/site/routecraft-build"
before=$(sha256sum /etc/config/dhcp /etc/config/network)
# Tailscale is intentionally unavailable; the resolver is not contacted by check.
printf 'n\n\n\n\n192.0.2.53\n\nn\n' |
    PATH="$tmp/bin:$PATH" ROUTECRAFT_DIR="$tmp/site" ROUTECRAFT_SECRET_DIR="$tmp/secrets" sh "$tmp/site/configure.sh" >"$tmp/out" 2>"$tmp/err"
grep -q 'Omitting initial rule' "$tmp/err"
grep -Fq 'Continuing the first installation without a subscription outbound.' "$tmp/err"
sha256sum -c "$tmp/site/candidate.sha256" >/dev/null
if grep -Eq 'vpn-sub|tailscale-exit' "$tmp/site/sing-box.candidate.json"; then echo 'unexpected VPN reference' >&2; exit 1; fi
[ ! -e "$tmp/site/sing-box.json" ] && [ ! -e "$tmp/site/.update.lock" ]
[ "$before" = "$(sha256sum /etc/config/dhcp /etc/config/network)" ]
echo 'first-install-no-vpn: passed (candidate only; no client traffic)'
