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
        if uclient-fetch -4 -O "$destination" "$url" && [ -s "$destination" ]; then
            return 0
        fi
        echo 'uclient-fetch failed over IPv4; trying another available downloader.' >&2
        rm -f "$destination"
    fi
    if command -v curl >/dev/null 2>&1; then
        if curl -4 -fL --connect-timeout 10 --max-time 180 "$url" -o "$destination" && [ -s "$destination" ]; then
            return 0
        fi
        echo 'curl failed over IPv4.' >&2
        rm -f "$destination"
    fi
    if command -v wget >/dev/null 2>&1; then
        if wget -4 -O "$destination" "$url" && [ -s "$destination" ]; then
            return 0
        fi
        echo 'wget failed over IPv4.' >&2
        rm -f "$destination"
    fi
    echo "ERROR: all available downloaders failed for $url" >&2
    return 1
}

download_release_asset() {
    asset_name=$1
    destination=$2
    asset_url=$(jsonfilter -i "$temporary/release.json" -e "@.assets[@.name='$asset_name'].url" 2>/dev/null || true)
    if [ -z "$asset_url" ]; then
        echo "ERROR: release asset not found: $asset_name" >&2
        return 1
    fi

    if command -v uclient-fetch >/dev/null 2>&1; then
        if uclient-fetch -4 --header='Accept: application/octet-stream' -O "$destination" "$asset_url" && [ -s "$destination" ]; then
            return 0
        fi
        echo 'uclient-fetch could not download the release asset; trying another available downloader.' >&2
        rm -f "$destination"
    fi
    if command -v curl >/dev/null 2>&1; then
        if curl -4 -fL -H 'Accept: application/octet-stream' --connect-timeout 10 --max-time 180 "$asset_url" -o "$destination" && [ -s "$destination" ]; then
            return 0
        fi
        echo 'curl could not download the release asset.' >&2
        rm -f "$destination"
    fi
    if command -v wget >/dev/null 2>&1; then
        if wget -4 --header='Accept: application/octet-stream' -O "$destination" "$asset_url" && [ -s "$destination" ]; then
            return 0
        fi
        echo 'wget could not download the release asset.' >&2
        rm -f "$destination"
    fi
    echo "ERROR: all available downloaders failed for release asset $asset_name" >&2
    return 1
}

temporary=$(mktemp -d /tmp/routecraft-install.XXXXXX)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
archive="routecraft-poc-openwrt-$bundle_arch.tar.gz"
release_api="https://api.github.com/repos/$repository/releases/latest"
download "$release_api" "$temporary/release.json"
download_release_asset "$archive" "$temporary/$archive"
download_release_asset "$archive.sha256" "$temporary/$archive.sha256"
(cd "$temporary" && sha256sum -c "$archive.sha256")
tar -xzf "$temporary/$archive" -C "$temporary"

echo "Installing RouteCraft PoC for $system_arch. The helper will install missing OpenWrt packages."
sh "$temporary/install.sh" --install
sh /etc/routecraft-poc/configure.sh
