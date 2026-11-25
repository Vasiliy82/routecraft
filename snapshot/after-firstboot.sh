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
