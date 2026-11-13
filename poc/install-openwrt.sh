#!/bin/sh
# Bootstrap RouteCraft from the latest public GitHub Release on a clean OpenWrt router.
set -eu

repository=${ROUTECRAFT_GITHUB_REPOSITORY:-Vasiliy82/routecraft}
system_arch=$(uname -m)
case "$system_arch" in
    x86_64|amd64) bundle_arch=amd64 ;;
    aarch64|arm64) bundle_arch=arm64 ;;
    armv7l|armv7*) bundle_arch=armv7 ;;
    *) echo "Unsupported OpenWrt CPU architecture: $system_arch" >&2; exit 1 ;;
esac

download() {
    url=$1
    destination=$2
    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -O "$destination" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 10 --max-time 180 "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$destination" "$url"
    else
        echo 'No HTTPS download client is available (expected uclient-fetch, curl, or wget).' >&2
        exit 1
    fi
}

temporary=$(mktemp -d /tmp/routecraft-install.XXXXXX)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
archive="routecraft-poc-openwrt-$bundle_arch.tar.gz"
release="https://github.com/$repository/releases/latest/download"
download "$release/$archive" "$temporary/$archive"
download "$release/$archive.sha256" "$temporary/$archive.sha256"
(cd "$temporary" && sha256sum -c "$archive.sha256")
tar -xzf "$temporary/$archive" -C "$temporary"

echo "Installing RouteCraft PoC for $system_arch. The helper will install missing OpenWrt packages."
sh "$temporary/install.sh" --install
sh /etc/routecraft-poc/configure.sh
