#!/bin/sh
# Check extracted release scripts on a POSIX host without changing networking.
set -eu
bundle=${1:?Pass the bundle archive path}
bundle_dir=$(CDPATH= cd -- "$(dirname -- "$bundle")" && pwd)
archive=$(basename "$bundle")
case "$archive" in
    routecraft-openwrt-amd64.tar.gz|routecraft-openwrt-arm64.tar.gz|routecraft-openwrt-armv7.tar.gz) ;;
    *) echo "Unexpected bundle name: $archive" >&2; exit 1 ;;
esac
arch=${archive#routecraft-openwrt-}
arch=${arch%.tar.gz}
(cd "$bundle_dir" && sha256sum -c "$archive.sha256")
work=$(mktemp -d /tmp/routecraft-bundle-test.XXXXXX)
case "$work" in /tmp/routecraft-bundle-test.*) ;; *) echo 'Unexpected temporary path' >&2; exit 1;; esac
trap 'rm -rf "$work"' EXIT HUP INT TERM
tar -xzf "$bundle" -C "$work"
[ "$(cat "$work/TARGET_ARCH")" = "$arch" ]
[ -s "$work/bin/routecraft-build" ]
[ -f "$work/routecraft.init" ]
if find "$work" \( -name 'routecraft-poc*' -o -name 'routecraft-lab*' -o -name 'subscription-poc.sh' \) | grep -q .; then
    echo 'Bundle contains obsolete RouteCraft file names' >&2
    exit 1
fi
cr=$(printf '\r')
for name in configure.sh install.sh start.sh subscription.sh subscription-probe.sh dnsmasq-split.sh direct-gateway.sh tproxy-gateway.sh routecraft.init; do
    [ -s "$work/$name" ]
    if grep -q "$cr" "$work/$name"; then echo "CRLF in $name" >&2; exit 1; fi
    sh -n "$work/$name"
done
(cd / && sh "$work/subscription.sh" --help) | grep -q '^Usage: subscription.sh'
grep -q '^dir=/etc/routecraft$' "$work/routecraft.init"
grep -q '^sh /etc/routecraft/configure.sh$' "$(dirname -- "$0")/../../poc/install-openwrt.sh"
mkdir "$work/bin-stubs"
cat >"$work/bin-stubs/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "$BUNDLE_ARCH"
EOF
cat >"$work/bin-stubs/uclient-fetch" <<'EOF'
#!/bin/sh
[ "$#" -eq 4 ] && [ "$1" = -4 ] && [ "$2" = -O ]
cp "$BUNDLE_DIR/${4##*/}" "$3"
EOF
cat >"$work/bin-stubs/sh" <<'EOF'
#!/bin/sh
case "$1" in
    */install.sh)
        [ "$2" = --install ] && [ -x "${1%/install.sh}/bin/routecraft-build" ]
        ;;
    /etc/routecraft/configure.sh) exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod 700 "$work/bin-stubs/"*
BUNDLE_ARCH="$arch" BUNDLE_DIR="$bundle_dir" PATH="$work/bin-stubs:$PATH" \
    "$(command -v sh)" "$(dirname -- "$0")/../../poc/install-openwrt.sh"

if env -i PATH="$PATH" ROUTECRAFT_DIR="$work/empty" sh "$work/start.sh" >"$work/out" 2>&1; then
    echo 'start.sh unexpectedly succeeded without DNS' >&2; exit 1
fi
grep -q 'ERROR: set ROUTECRAFT_DNS_UPSTREAM' "$work/out"
if env -i PATH="$PATH" ROUTECRAFT_DIR="$work/empty" ROUTECRAFT_DNS_UPSTREAM=192.0.2.53 sh "$work/start.sh" >"$work/out" 2>&1; then
    echo 'start.sh unexpectedly succeeded without an exit node' >&2; exit 1
fi
grep -q 'ERROR: set ROUTECRAFT_EXIT_NODE' "$work/out"
echo 'Extracted bundle shell checks passed'
