#!/usr/bin/env bash
# One-shot Ubuntu GNOME desktop rootfs for userdata.
# qemu-user; first run takes a long time. Needs ROOT_PASSWORD.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUITE="${SUITE:-resolute}"
export MIRROR="${MIRROR:-http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports}"
export ROOTFS="${ROOTFS:-$ROOT/out/rootfs-desktop}"
export IMG="${IMG:-$ROOT/out/rootfs-desktop.ext4}"
export SIZE="${SIZE:-8G}"
export SKIP_HOST_SSH_KEY="${SKIP_HOST_SSH_KEY:-1}"
# Minbase + gadget/resize only. GNOME comes from rootfs-desktop-setup.sh.
export DESKTOP=0
COMPRESS="${COMPRESS:-1}"

PASS="${ROOT_PASSWORD:-}"
if [[ -z "$PASS" && -f "$ROOT/out/root-password" ]]; then
	PASS=$(cat "$ROOT/out/root-password")
	export ROOT_PASSWORD="$PASS"
fi
if [[ -z "$PASS" ]]; then
	echo "set ROOT_PASSWORD (do not commit it)" >&2
	exit 1
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
	exec sudo --preserve-env=SUITE,MIRROR,ROOTFS,IMG,SIZE,SKIP_HOST_SSH_KEY,DESKTOP,ROOT_PASSWORD,COMPRESS,BASE_URL,BASE_TGZ "$0" "$@"
fi

FW="$ROOT/firmware/dagu/lib/firmware"
if [[ ! -d "$FW" ]]; then
	echo "==> firmware missing — stage-firmware.sh (Wi-Fi / GPU / audio blobs)"
	"$ROOT/scripts/stage-firmware.sh" || true
fi

echo "==> minbase $SUITE -> $ROOTFS"
"$ROOT/scripts/build-rootfs.sh"

chroot_mount() {
	mkdir -p "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev/pts"
	mountpoint -q "$ROOTFS/proc" || mount -t proc proc "$ROOTFS/proc"
	mountpoint -q "$ROOTFS/sys" || mount -t sysfs sys "$ROOTFS/sys"
	mountpoint -q "$ROOTFS/dev" || mount --bind /dev "$ROOTFS/dev"
	mountpoint -q "$ROOTFS/dev/pts" || mount --bind /dev/pts "$ROOTFS/dev/pts"
	if [[ -f /run/systemd/resolve/resolv.conf ]]; then
		cp /run/systemd/resolve/resolv.conf "$ROOTFS/etc/resolv.conf"
	elif [[ -f /etc/resolv.conf ]]; then
		cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
	fi
}

chroot_umount() {
	umount -l "$ROOTFS/dev/pts" 2>/dev/null || true
	umount -l "$ROOTFS/dev" 2>/dev/null || true
	umount -l "$ROOTFS/sys" 2>/dev/null || true
	umount -l "$ROOTFS/proc" 2>/dev/null || true
}
trap chroot_umount EXIT

# Desktop keeps g_serial; RNDIS would steal the UDC.
rm -f "$ROOTFS/etc/systemd/system/multi-user.target.wants/dagu-usb-rndis.service"

echo "==> rootfs-desktop-setup.sh (GNOME + UCM + tablet session)"
chroot_mount
rm -rf "$ROOTFS/tmp/dagu-userspace" "$ROOTFS/tmp/dagu-camera-loopback"
cp -a "$ROOT/userspace" "$ROOTFS/tmp/dagu-userspace"
cp -a "$ROOT/camera-loopback" "$ROOTFS/tmp/dagu-camera-loopback"
install -m 755 "$ROOT/scripts/rootfs-desktop-setup.sh" "$ROOTFS/tmp/rootfs-desktop-setup.sh"
chroot "$ROOTFS" env ROOT_PASSWORD="$PASS" SUITE="$SUITE" MIRROR="$MIRROR" \
	/bin/bash /tmp/rootfs-desktop-setup.sh
rm -rf "$ROOTFS/tmp/rootfs-desktop-setup.sh" \
	"$ROOTFS/tmp/dagu-userspace" "$ROOTFS/tmp/dagu-camera-loopback"

# Public image: no builder SSH keys, new machine-id on first boot.
rm -rf "$ROOTFS/root/.ssh"
mkdir -p "$ROOTFS/root/.ssh"
chmod 700 "$ROOTFS/root/.ssh"
rm -f "$ROOTFS/etc/ssh/ssh_host_"*
rm -f "$ROOTFS/var/lib/dbus/machine-id"
: >"$ROOTFS/etc/machine-id"
chroot "$ROOTFS" dpkg-reconfigure -f noninteractive openssh-server >/dev/null 2>&1 || true

chroot_umount
trap - EXIT

echo "==> ext4 $IMG ($SIZE)"
"$ROOT/scripts/build-rootfs-image.sh"

if [[ "$COMPRESS" == 1 ]]; then
	echo "==> zstd $IMG"
	zstd -T0 -19 -f -k "$IMG" -o "${IMG}.zst"
	(cd "$(dirname "$IMG")" && sha256sum "$(basename "$IMG")" "$(basename "$IMG").zst" \
		| tee "$(dirname "$IMG")/rootfs-desktop.SHA256SUMS")
	ls -lh "$IMG" "${IMG}.zst"
fi

echo "Flash (wipes Android /data): ./scripts/flash-rootfs.sh"
echo "Then kernel slot B only:     ./scripts/flash-boot.sh flash-b"
