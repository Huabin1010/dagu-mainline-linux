#!/usr/bin/env bash
# Ubuntu arm64 rootfs for userdata. Replaces Android.
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

if [[ ! -d "$ROOTFS/bin" ]]; then
	echo "==> debootstrap $SUITE arm64 -> $ROOTFS"
	echo "    This image is flashed to userdata and wipes Android."
	debootstrap --arch=arm64 --variant=minbase "$SUITE" "$ROOTFS" "$MIRROR"
	chroot "$ROOTFS" apt-get update
	chroot "$ROOTFS" apt-get install -y --no-install-recommends \
		systemd systemd-sysv openssh-server sudo kmod udev \
		iproute2 iputils-ping ca-certificates alsa-utils \
		e2fsprogs mesa-vulkan-drivers || true
	echo dagu >"$ROOTFS/etc/hostname"
else
	echo "rootfs already at $ROOTFS — refreshing dagu config"
fi

PASS="${ROOT_PASSWORD:-}"
if [[ -z "$PASS" && -f "$ROOT/out/root-password" ]]; then
	PASS=$(cat "$ROOT/out/root-password")
fi
if [[ -n "$PASS" ]]; then
	echo "root:$PASS" | chroot "$ROOTFS" chpasswd
	echo "==> root password updated"
fi

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$ROOTFS/etc/ssh/sshd_config" || true
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$ROOTFS/etc/ssh/sshd_config" || true
mkdir -p "$ROOTFS/root/.ssh" "$ROOTFS/usr/local/sbin" "$ROOTFS/etc/systemd/system" \
	"$ROOTFS/etc/systemd/system/multi-user.target.wants"
chmod 700 "$ROOTFS/root/.ssh"
if [[ -f "$ROOT/out/id_dagu.pub" ]]; then
	install -m 600 "$ROOT/out/id_dagu.pub" "$ROOTFS/root/.ssh/authorized_keys"
fi

printf '%s\n' 'LABEL=dagu-linux / ext4 defaults 0 1' >"$ROOTFS/etc/fstab"

cat >"$ROOTFS/usr/local/sbin/dagu-usb-rndis.sh" <<'EOF'
#!/bin/sh
G=/sys/kernel/config/usb_gadget/dagu
mkdir -p /sys/kernel/config
mount -t configfs none /sys/kernel/config 2>/dev/null || true
mkdir -p "$G/strings/0x409" "$G/configs/c.1/strings/0x409" "$G/functions/rndis.usb0"
echo 0x1d6b >"$G/idVendor"
echo 0x0104 >"$G/idProduct"
echo dagu-mainline >"$G/strings/0x409/serialnumber"
echo xiaomi-pad870-win11-arm >"$G/strings/0x409/manufacturer"
echo "dagu USB RNDIS" >"$G/strings/0x409/product"
echo RNDIS >"$G/configs/c.1/strings/0x409/configuration"
echo 02:00:00:00:07:01 >"$G/functions/rndis.usb0/host_addr"
echo 02:00:00:00:07:02 >"$G/functions/rndis.usb0/dev_addr"
ln -sf "$G/functions/rndis.usb0" "$G/configs/c.1/rndis.usb0"
UDC=
for d in /sys/class/udc/*; do
	[ -e "$d" ] || continue
	UDC=$(basename "$d")
	break
done
[ -n "$UDC" ] && echo "$UDC" >"$G/UDC"
for i in 1 2 3 4 5 6 7 8 9 10; do
	ip addr add 192.168.7.2/24 dev usb0 2>/dev/null && break
	sleep 1
done
ip link set usb0 up 2>/dev/null || true
EOF
chmod 755 "$ROOTFS/usr/local/sbin/dagu-usb-rndis.sh"

cat >"$ROOTFS/etc/systemd/system/dagu-usb-rndis.service" <<'EOF'
[Unit]
Description=dagu USB RNDIS
After=sysinit.target
Before=ssh.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/dagu-usb-rndis.sh

[Install]
WantedBy=multi-user.target
EOF

cat >"$ROOTFS/usr/local/sbin/dagu-resize-root.sh" <<'EOF'
#!/bin/sh
dev=$(awk '$2 == "/" { print $1; exit }' /proc/mounts)
[ -n "$dev" ] && resize2fs "$dev"
EOF
chmod 755 "$ROOTFS/usr/local/sbin/dagu-resize-root.sh"

cat >"$ROOTFS/etc/systemd/system/dagu-resize-root.service" <<'EOF'
[Unit]
Description=Grow Ubuntu ext4 on userdata
After=local-fs.target
ConditionPathExists=/sbin/resize2fs

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dagu-resize-root.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

ln -sf /etc/systemd/system/dagu-usb-rndis.service \
	"$ROOTFS/etc/systemd/system/multi-user.target.wants/dagu-usb-rndis.service"
ln -sf /etc/systemd/system/dagu-resize-root.service \
	"$ROOTFS/etc/systemd/system/multi-user.target.wants/dagu-resize-root.service"
ln -sf /lib/systemd/system/ssh.service \
	"$ROOTFS/etc/systemd/system/multi-user.target.wants/ssh.service" 2>/dev/null || \
ln -sf /usr/lib/systemd/system/ssh.service \
	"$ROOTFS/etc/systemd/system/multi-user.target.wants/ssh.service" || true

FW="$ROOT/firmware/dagu/lib/firmware"
if [[ -d "$FW" ]]; then
	mkdir -p "$ROOTFS/lib/firmware"
	cp -a "$FW/." "$ROOTFS/lib/firmware/"
	echo "==> staged firmware into rootfs"
fi
echo "==> $ROOTFS"
du -sh "$ROOTFS"
echo "Pack:  ./scripts/build-rootfs-image.sh"
echo "Flash: ./scripts/flash-rootfs.sh   # fastboot flash userdata (wipes Android)"
