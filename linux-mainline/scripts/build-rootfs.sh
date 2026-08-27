#!/usr/bin/env bash
# Ubuntu arm64 rootfs for an independent Linux partition — NEVER userdata.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${ROOTFS:-$ROOT/out/rootfs}"
SUITE="${SUITE:-noble}"
MIRROR="${MIRROR:-http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
	exec sudo "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive
command -v debootstrap >/dev/null || apt-get install -y debootstrap
if ! command -v qemu-aarch64 >/dev/null && ! command -v qemu-aarch64-static >/dev/null; then
	apt-get install -y qemu-user qemu-user-binfmt || \
	apt-get install -y qemu-user-hwe qemu-user-binfmt-hwe
fi
update-binfmts --enable qemu-aarch64 >/dev/null 2>&1 || true

if [[ -d "$ROOTFS/bin" ]]; then
	echo "rootfs already at $ROOTFS"
	exit 0
fi

echo "==> debootstrap $SUITE arm64 -> $ROOTFS"
echo "    This image must be flashed to a NEW partition, not Android userdata."
debootstrap --arch=arm64 --variant=minbase "$SUITE" "$ROOTFS" "$MIRROR"
chroot "$ROOTFS" apt-get update
chroot "$ROOTFS" apt-get install -y --no-install-recommends \
	systemd systemd-sysv openssh-server sudo kmod udev \
	iproute2 iputils-ping ca-certificates alsa-utils \
	mesa-vulkan-drivers || true
echo "root:dagu" | chroot "$ROOTFS" chpasswd
echo dagu >"$ROOTFS/etc/hostname"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$ROOTFS/etc/ssh/sshd_config" || true
mkdir -p "$ROOTFS/root/.ssh"
chmod 700 "$ROOTFS/root/.ssh"
if [[ -f "$ROOT/out/id_dagu.pub" ]]; then
	install -m 600 "$ROOT/out/id_dagu.pub" "$ROOTFS/root/.ssh/authorized_keys"
fi

FW="$ROOT/firmware/dagu/lib/firmware"
if [[ -d "$FW" ]]; then
	mkdir -p "$ROOTFS/lib/firmware"
	cp -a "$FW/." "$ROOTFS/lib/firmware/"
	echo "==> staged firmware into rootfs"
fi
echo "==> $ROOTFS"
du -sh "$ROOTFS"
echo "Pack: ./scripts/build-rootfs-image.sh"
echo "Flash (example, NOT userdata): fastboot flash linux out/rootfs.ext4"
