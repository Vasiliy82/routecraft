#!/bin/sh
set -eu
umask 077

fail() {
	printf '%s\n' "snapshotctl: $*" >&2
	exit 1
}

usage() {
	cat <<'HELP'
snapshotctl create NAME
snapshotctl list
snapshotctl restore NAME   # write userdata and immediately force reboot
snapshotctl delete NAME
HELP
}

case "${1:-}" in
	''|help|-h|--help) usage; exit 0 ;;
	list) [ "$#" -eq 1 ] || fail 'usage: snapshotctl list' ;;
	create|restore|delete)
		[ "$#" -eq 2 ] || fail "usage: snapshotctl $1 NAME"
		case "$2" in
			''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) fail 'invalid snapshot name' ;;
		esac
		[ "${#2}" -le 64 ] || fail 'snapshot name is longer than 64 characters'
		;;
	*) fail 'unknown command. See snapshotctl help' ;;
esac

[ "$(id -u)" = 0 ] || fail 'run as root'
data=$(sh /persistent/bin/after-firstboot.sh --userdata)
store=/persistent/snapshots
[ -d "$store" ] && [ ! -L "$store" ] && [ "$(stat -c '%u:%a' "$store")" = '0:700' ] ||
	fail 'run setup.sh to configure the snapshot directory'
exec 9>"$store/.lock"
flock -n 9 || fail 'another snapshot command is running'
if [ "$1" = list ]; then
	for file in "$store"/*.img; do
		[ -f "$file" ] && [ ! -L "$file" ] || continue
		name=${file##*/}
		printf '%s\n' "${name%.img}"
	done
	exit 0
fi

image=$store/$2.img
case "$1" in
	create)
		[ ! -e "$image" ] && [ ! -L "$image" ] || fail 'snapshot already exists'
		bytes=$(blockdev --getsize64 "$data")
		free_kb=$(df -Pk "$store" | awk 'END {print $4}')
		[ "$free_kb" -gt "$((bytes / 1024))" ] || fail 'not enough free space'
		tmp=$(mktemp "$store/.capture.XXXXXX")
		trap 'rm -f "$tmp"' EXIT
		trap 'exit 1' HUP INT TERM
		dd if="$data" of="$tmp" bs=1M conv=fsync
		[ "$(stat -c '%s' "$tmp")" -eq "$bytes" ] || fail 'short read from userdata'
		mv -T "$tmp" "$image"
		;;
	restore)
		[ -f "$image" ] && [ ! -L "$image" ] || fail 'snapshot not found'
		[ "$(stat -c '%s' "$image")" -eq "$(blockdev --getsize64 "$data")" ] ||
			fail 'snapshot size differs from userdata'
		dd if="$image" of="$data" bs=1M conv=fsync ||
			fail 'write failed; userdata may be partially overwritten'
		exec reboot -f
		;;
	delete)
		[ -f "$image" ] && [ ! -L "$image" ] || fail 'snapshot not found'
		rm "$image"
		;;
esac
