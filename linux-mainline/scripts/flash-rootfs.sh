#!/usr/bin/env bash
# Flash Ubuntu to userdata. Wipes Android userspace.
# Does not write boot_a/boot_b/dtbo/super — A/B boot chain stays stock.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/fastboot-common.sh
source "$ROOT/scripts/fastboot-common.sh"
IMG="${IMG:-}"
WAIT="${WAIT:-60}"
SPARSE="${SPARSE:-256M}"

pick_img() {
	local c
	if [[ -n "${IMG}" ]]; then
		echo "${IMG}"
		return
	fi
	for c in \
		"$ROOT/out/rootfs-desktop.ext4.zst" \
		"$ROOT/out/rootfs-desktop.ext4.xz" \
		"$ROOT/out/rootfs-desktop.ext4" \
		"$ROOT/out/rootfs.ext4.zst" \
		"$ROOT/out/rootfs.ext4.xz" \
		"$ROOT/out/rootfs.ext4"; do
		if [[ -f "$c" ]]; then
			echo "$c"
			return
		fi
	done
	echo "missing rootfs image — download a release asset or run build-rootfs-desktop.sh" >&2
	exit 1
}

unpack_img() {
	local src=$1 dest
	case "$src" in
	*.zst)
		command -v zstd >/dev/null || {
			echo "need zstd to unpack $src" >&2
			exit 1
		}
		dest="${src%.zst}"
		if [[ ! -f "$dest" || "$src" -nt "$dest" ]]; then
			echo "==> zstd -d $src"
			zstd -d -f -T0 -k "$src" -o "$dest"
		fi
		echo "$dest"
		;;
	*.xz)
		command -v xz >/dev/null || {
			echo "need xz to unpack $src" >&2
			exit 1
		}
		dest="${src%.xz}"
		if [[ ! -f "$dest" || "$src" -nt "$dest" ]]; then
			echo "==> xz -d $src"
			xz -dkf "$src"
		fi
		echo "$dest"
		;;
	*)
		echo "$src"
		;;
	esac
}

IMG=$(pick_img)
IMG=$(unpack_img "$IMG")
[[ -f "$IMG" ]] || {
	echo "missing $IMG" >&2
	exit 1
}

wait_fastboot
assert_unlocked
print_ab_status

echo
echo "This only writes userdata (not A/B). Android /data is gone; boot_a and"
echo "boot_b stay stock. fastboot / EDL still work. To get HyperOS back:"
echo "  flash_all / EDL 官方包（不要 lock）。"
echo
echo "Do not: fastboot reboot   (ABL would load Android boot_\$slot, which"
echo "        cannot mount Ubuntu userdata)."
echo "Do:     ./scripts/flash-boot.sh flash-b"
echo
echo "fb-usb.py flash -S $SPARSE userdata  (not boot_a/boot_b)"
python3 "$FBUSB" flash -S "$SPARSE" userdata "$IMG"
echo "==> flashed userdata <- $IMG"
echo "Now flash the kernel to slot B: ./scripts/flash-boot.sh flash-b"
