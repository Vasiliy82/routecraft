#!/bin/sh
set -eu
umask 077

[ "$#" -eq 0 ] || { echo 'usage: setup.sh' >&2; exit 1; }
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ -f "$here/snapshotctl.sh" ] || { echo 'keep the three scripts together' >&2; exit 1; }
sh "$here/after-firstboot.sh" --mount-only

bin=/persistent/bin
for dir in "$bin" /persistent/snapshots; do
	[ -d "$dir" ] || mkdir -m 0700 "$dir"
	if [ -L "$dir" ] || [ "$(stat -c '%u:%a' "$dir")" != '0:700' ]; then
		echo "$dir must be a root-owned directory with mode 0700" >&2
		exit 1
	fi
done

install_script() {
	tmp=$(mktemp "$bin/.setup.XXXXXX")
	if ! cat "$1" > "$tmp" || ! chmod 0700 "$tmp" || ! mv -fT "$tmp" "$bin/$2"; then
		rm -f "$tmp"
		return 1
	fi
}

install_script "$here/snapshotctl.sh" snapshotctl
install_script "$here/after-firstboot.sh" after-firstboot.sh
sh "$bin/after-firstboot.sh"
printf '%s\n' 'Ready. Run snapshotctl help.'
