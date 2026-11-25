#!/bin/sh
set -eu
umask 077

fail() {
	printf '%s\n' "snapshot setup: $*" >&2
	exit 1
}

write_recovery() {
	cat <<'SNAPSHOT_RECOVERY_SCRIPT'
#!/bin/sh
set -eu

fail() {
	printf '%s\n' "snapshot setup: $*" >&2
	exit 1
}

[ "$(id -u)" = 0 ] || fail 'run as root'
[ "$#" -le 1 ] || fail 'usage: after-firstboot.sh'
mode=${1:-}
case "$mode" in ''|--mount-only|--userdata) ;; *) fail 'usage: after-firstboot.sh' ;; esac

tr '\000' '\n' < /proc/device-tree/compatible | grep -qx 'friendlyelec,nanopi-r28s' ||
	fail 'expected NanoPi R28S'
data=$(awk '{for (i=1; i<=NF; i++) if ($i ~ /^data=/) {print substr($i,6)}}' /proc/cmdline)
printf '%s\n' "$data" | grep -Eq '^/dev/mmcblk[0-9]+p[1-9][0-9]*$' ||
	fail 'expected FriendlyWrt data= on MMC/SD'
[ -b "$data" ] && grep -qx 'PARTNAME=userdata' "/sys/class/block/${data##*/}/uevent" ||
	fail 'data= is not the userdata partition'

disk=${data%p*}
device=
for file in /sys/class/block/"${disk##*/}"p*/uevent; do
	[ -f "$file" ] && grep -qx 'PARTNAME=opt' "$file" || continue
	[ -z "$device" ] || fail 'ambiguous GPT partition opt'
	node=${file%/uevent}
	device=/dev/${node##*/}
done
[ -b "$device" ] || fail 'missing GPT partition opt'

target=/persistent
[ ! -L "$target" ] || fail "$target is a symbolic link"
major_minor=$(cat "/sys/class/block/${device##*/}/dev")
mounted=$(awk '$5 == "/persistent" {id=$3} END {print id}' /proc/self/mountinfo)
if [ -n "$mounted" ]; then
	[ "$mounted" = "$major_minor" ] || fail "$target is mounted from another device"
	awk -v dev="$major_minor" '$3 == dev && $4 == "/" && $5 == "/persistent" && / - ext4 / {ok=1} END {exit !ok}' /proc/self/mountinfo ||
		fail "$target must mount the ext4 volume root"
else
	[ "$mode" != --userdata ] || fail 'mount /persistent with after-firstboot.sh first'
	mkdir -p "$target"
	[ -z "$(ls -A "$target")" ] || fail "$target is not empty"
	mount -t ext4 -o rw,nosuid,nodev "$device" "$target"
fi

case "$mode" in
	--mount-only) exit 0 ;;
	--userdata) printf '%s\n' "$data"; exit 0 ;;
esac

[ -x "$target/bin/snapshotctl" ] || fail 'run setup.sh first'
link=/usr/bin/snapshotctl
if [ -L "$link" ]; then
	[ "$(readlink "$link")" = "$target/bin/snapshotctl" ] || fail "$link already exists"
else
	[ ! -e "$link" ] || fail "$link already exists"
fi

uuid=$(block info "$device" | sed -n 's/.* UUID="\([^"]*\)".*/\1/p')
[ -n "$uuid" ] || fail 'no ext4 UUID'
section=fstab.routecraft_snapshots
[ -f /etc/config/fstab ] || touch /etc/config/fstab
[ -z "$(uci changes fstab)" ] || fail 'finish existing UCI changes to fstab first'
if uci -q show fstab | grep -Fxv -e "$section.target='$target'" -e "$section.uuid='$uuid'" |
	grep -E "\\.(target='$target'|uuid='$uuid')$" >/dev/null; then
	fail 'another fstab section owns /persistent or the opt UUID'
fi
if uci -q get "$section" >/dev/null; then
	[ "$(uci -q get "$section")" = mount ] &&
	[ "$(uci -q get "$section.target")" = "$target" ] &&
	[ "$(uci -q get "$section.uuid")" = "$uuid" ] || fail "$section specifies a different mount"
fi
trap 'uci -q revert "$section" || :' EXIT
uci set "$section=mount"
uci set "$section.uuid=$uuid"
uci set "$section.target=$target"
uci set "$section.options=rw,nosuid,nodev"
uci set "$section.enabled=1"
uci commit fstab
trap - EXIT
/etc/init.d/fstab enable
[ -L "$link" ] || ln -s "$target/bin/snapshotctl" "$link"
SNAPSHOT_RECOVERY_SCRIPT
}

write_cli() {
	cat <<'SNAPSHOT_CLI_SCRIPT'
#!/bin/sh
set -eu
umask 077

version=0.2.1

fail() {
	printf '%s\n' "snapshotctl: $*" >&2
	exit 1
}

usage() {
	printf 'snapshotctl %s\n' "$version"
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
set -o pipefail
data=$(sh /persistent/bin/after-firstboot.sh --userdata)
store=/persistent/snapshots
[ -d "$store" ] && [ ! -L "$store" ] && [ "$(stat -c '%u:%a' "$store")" = '0:700' ] ||
	fail 'run setup.sh to configure the snapshot directory'
exec 9>"$store/.lock"
flock -n 9 || fail 'another snapshot command is running'

if [ "$1" = list ]; then
	for dir in "$store"/*.snapshot; do
		[ -d "$dir" ] && [ ! -L "$dir" ] || continue
		[ -f "$dir/image.gz" ] && [ -f "$dir/image.sha256" ] || continue
		name=${dir##*/}
		printf '%s\n' "${name%.snapshot}"
	done
	exit 0
fi

userdata_bytes() {
	# Linux reports block device size in units of 512 bytes here.
	sectors=$(cat "/sys/class/block/${data##*/}/size") || fail 'cannot read userdata size'
	case "$sectors" in ''|*[!0-9]*) fail 'invalid userdata size' ;; esac
	[ "$sectors" -gt 0 ] || fail 'invalid userdata size'
	printf '%s\n' "$((sectors * 512))"
}

checksum() {
	result=$(sha256sum "$1") || return 1
	printf '%s\n' "${result%% *}"
}

check_size() {
	bytes=$(userdata_bytes) || return 1
	decoded=$(gzip -dc "$1" | wc -c) || fail 'invalid gzip image'
	[ "$decoded" -eq "$bytes" ] || fail 'snapshot size differs from userdata'
}

snapshot=$store/$2.snapshot
image=$snapshot/image.gz
digest=$snapshot/image.sha256
case "$1" in
	create)
		[ ! -e "$snapshot" ] && [ ! -L "$snapshot" ] || fail 'snapshot already exists'
		tmp=$(mktemp -d "$store/.capture.XXXXXX")
		trap 'rm -f "$tmp/image.gz" "$tmp/image.sha256"; if [ -d "$tmp" ]; then rmdir "$tmp"; fi' EXIT
		trap 'exit 1' HUP INT TERM
		dd if="$data" bs=1M | gzip -1 > "$tmp/image.gz" ||
			fail 'cannot read userdata or write compressed snapshot'
		check_size "$tmp/image.gz"
		checksum "$tmp/image.gz" > "$tmp/image.sha256"
		mv -T "$tmp" "$snapshot"
		sync
		;;
	restore)
		[ -d "$snapshot" ] && [ ! -L "$snapshot" ] || fail 'snapshot not found'
		[ -f "$image" ] && [ ! -L "$image" ] && [ -f "$digest" ] && [ ! -L "$digest" ] ||
			fail 'snapshot is missing its image or checksum'
		actual=$(checksum "$image") || fail 'cannot calculate snapshot checksum'
		expected=$(cat "$digest") || fail 'cannot read snapshot checksum'
		[ "$actual" = "$expected" ] || fail 'snapshot SHA-256 mismatch'
		check_size "$image"
		gzip -dc "$image" | dd of="$data" bs=1M conv=fsync ||
			fail 'write failed; userdata may be partially overwritten'
		exec reboot -f
		;;
	delete)
		[ -d "$snapshot" ] && [ ! -L "$snapshot" ] || fail 'snapshot not found'
		rm -f "$image" "$digest"
		rmdir "$snapshot"
		;;
esac
SNAPSHOT_CLI_SCRIPT
}

install_script() {
	staged=$(mktemp "$bin/.setup.XXXXXX")
	"$1" > "$staged"
	chmod 0700 "$staged"
	mv -fT "$staged" "$bin/$2"
	staged=
}

main() {
	[ "$(id -u)" = 0 ] || fail 'run as root'
	case "$#:${1:-}" in
		0:|1:recover) ;;
		*) fail 'usage: sh setup.sh [recover]' ;;
	esac

	bin=/persistent/bin
	bootstrap=$(mktemp)
	staged=
	trap 'rm -f "$bootstrap" "${staged:-$bootstrap}"' EXIT
	trap 'exit 1' HUP INT TERM
	write_recovery > "$bootstrap"
	sh "$bootstrap" --mount-only

	if [ "${1:-}" != recover ]; then
		for dir in "$bin" /persistent/snapshots; do
			[ ! -L "$dir" ] || fail "$dir is a symbolic link"
			[ -d "$dir" ] || mkdir -m 0700 "$dir"
			[ "$(stat -c '%u:%a' "$dir")" = '0:700' ] ||
				fail "$dir must be a root-owned directory with mode 0700"
		done
		install_script write_cli snapshotctl
		install_script write_recovery after-firstboot.sh
	fi

	[ -x "$bin/after-firstboot.sh" ] || fail 'run the installer without recover first'
	sh "$bin/after-firstboot.sh"
	printf '%s\n' 'Ready. Run snapshotctl help.'
}

main "$@"
