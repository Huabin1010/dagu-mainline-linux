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

chroot_mount() {
	mkdir -p "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev/pts"
	mountpoint -q "$ROOTFS/proc" || mount -t proc proc "$ROOTFS/proc"
	mountpoint -q "$ROOTFS/sys" || mount -t sysfs sys "$ROOTFS/sys"
	mountpoint -q "$ROOTFS/dev" || mount --bind /dev "$ROOTFS/dev"
	mountpoint -q "$ROOTFS/dev/pts" || mount --bind /dev/pts "$ROOTFS/dev/pts"
	# systemd stub 127.0.0.53 is not a resolver inside the chroot.
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

if [[ ! -d "$ROOTFS/bin" ]]; then
	echo "==> bootstrap $SUITE arm64 -> $ROOTFS"
	echo "    This image is flashed to userdata and wipes Android."
	mkdir -p "$ROOTFS"
	BASE_TGZ="${BASE_TGZ:-$ROOT/out/ubuntu-base-${SUITE}-arm64.tar.gz}"
	BASE_URL="${BASE_URL:-}"
	if [[ "$SUITE" == resolute && -z "$BASE_URL" ]]; then
		BASE_URL="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/26.04.1/release/ubuntu-base-26.04.1-base-arm64.tar.gz"
	fi
	if [[ -n "$BASE_URL" ]]; then
		if [[ ! -f "$BASE_TGZ" ]]; then
			echo "==> fetch $BASE_URL"
			curl -fL --retry 3 -o "$BASE_TGZ" "$BASE_URL"
		fi
		tar -xzf "$BASE_TGZ" -C "$ROOTFS"
	else
		debootstrap --arch=arm64 --variant=minbase "$SUITE" "$ROOTFS" "$MIRROR"
	fi
	QEMU_BIN="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
	if [[ -n "$QEMU_BIN" ]]; then
		install -m 755 "$QEMU_BIN" "$ROOTFS/usr/bin/qemu-aarch64-static"
	fi
	printf '# see sources.list.d/ubuntu.sources\n' >"$ROOTFS/etc/apt/sources.list"
	mkdir -p "$ROOTFS/etc/apt/sources.list.d"
	cat >"$ROOTFS/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: $MIRROR
Suites: $SUITE $SUITE-updates $SUITE-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
	chroot_mount
	chroot "$ROOTFS" apt-get update
	chroot "$ROOTFS" apt-get install -y --no-install-recommends \
		systemd systemd-sysv openssh-server sudo kmod udev \
		iproute2 iputils-ping ca-certificates alsa-utils \
		e2fsprogs mesa-vulkan-drivers || true
	echo dagu >"$ROOTFS/etc/hostname"
else
	echo "rootfs already at $ROOTFS — refreshing dagu config"
	chroot_mount
fi

if [[ "${DESKTOP:-0}" == 1 ]]; then
	echo "==> Ubuntu Desktop ($SUITE) — qemu-user, this takes a while"
	# Prefer deb822; keep sources.list empty so apt does not double the suites.
	printf '# see sources.list.d/ubuntu.sources\n' >"$ROOTFS/etc/apt/sources.list"
	mkdir -p "$ROOTFS/etc/apt/sources.list.d"
	cat >"$ROOTFS/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: $MIRROR
Suites: $SUITE $SUITE-updates $SUITE-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
	chroot "$ROOTFS" apt-get update
	# Minimal GNOME session. Full ubuntu-desktop pulls snaps/firefox that
	# qemu-debootstrap often cannot finish; install the session + GDM.
	chroot "$ROOTFS" apt-get install -y --no-install-recommends \
		ubuntu-desktop-minimal gdm3 gnome-session gnome-terminal \
		gnome-control-center gnome-settings-daemon nautilus \
		dbus-user-session policykit-1 \
		libgl1-mesa-dri libgbm1 mesa-vulkan-drivers \
		libinput-bin xserver-xorg-input-libinput \
		fonts-noto-core fonts-noto-cjk \
		network-manager || true
	# On-screen keyboard for a tablet with no keys.
	chroot "$ROOTFS" apt-get install -y --no-install-recommends \
		onboard || chroot "$ROOTFS" apt-get install -y --no-install-recommends \
		gnome-shell-extensions || true
		chroot "$ROOTFS" systemctl set-default graphical.target || true
		chroot "$ROOTFS" systemctl enable gdm3.service || true
		# Keep USB serial after switch_root (g_serial is built-in).
		chroot "$ROOTFS" systemctl enable serial-getty@ttyGS0.service || true
		chroot "$ROOTFS" systemctl enable serial-getty@tty0.service || true
fi

PASS="${ROOT_PASSWORD:-}"
if [[ -z "$PASS" && -f "$ROOT/out/root-password" ]]; then
	PASS=$(cat "$ROOT/out/root-password")
fi
if [[ -n "$PASS" ]]; then
	echo "root:$PASS" | chroot "$ROOTFS" chpasswd
	echo "==> root password updated"
	if [[ "${DESKTOP:-0}" == 1 ]]; then
		chroot "$ROOTFS" useradd -m -s /bin/bash -G sudo,video,render,input,plugdev dagu 2>/dev/null || true
		echo "dagu:$PASS" | chroot "$ROOTFS" chpasswd
		echo 'dagu ALL=(ALL) NOPASSWD:ALL' >"$ROOTFS/etc/sudoers.d/dagu"
		chmod 440 "$ROOTFS/etc/sudoers.d/dagu"
		mkdir -p "$ROOTFS/etc/gdm3"
		cat >"$ROOTFS/etc/gdm3/custom.conf" <<'EOF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=dagu
WaylandEnable=true
EOF
		# Desktop env lives in rootfs-desktop-setup.sh. Do not force cairo /
		# llvmpipe (GDM SIGSEGV) or autostart onboard (steals Wayland touch).
		rm -f "$ROOTFS/etc/environment.d/dagu-swrend.conf"
		rm -f "$ROOTFS/home/dagu/.config/autostart/onboard.desktop"
		mkdir -p "$ROOTFS/home/dagu/.config/autostart"
		chroot "$ROOTFS" chown -R dagu:dagu /home/dagu
		# Screen keyboard via GNOME a11y if onboard is missing.
		mkdir -p "$ROOTFS/etc/dconf/db/local.d"
		cat >"$ROOTFS/etc/dconf/db/local.d/00-dagu-tablet" <<'EOF'
[org/gnome/desktop/a11y/applications]
screen-keyboard-enabled=true

[org/gnome/desktop/interface]
toolkit-accessibility=true
EOF
		chroot "$ROOTFS" dconf update 2>/dev/null || true
	fi
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
# Ubuntu puts resize2fs in /usr/sbin, not /sbin.
dev=$(awk '$2 == "/" { print $1; exit }' /proc/mounts)
[ -n "$dev" ] || exit 0
for bin in /usr/sbin/resize2fs /sbin/resize2fs resize2fs; do
	command -v "$bin" >/dev/null 2>&1 || continue
	exec "$bin" "$dev"
done
exit 1
EOF
chmod 755 "$ROOTFS/usr/local/sbin/dagu-resize-root.sh"

cat >"$ROOTFS/etc/systemd/system/dagu-resize-root.service" <<'EOF'
[Unit]
Description=Grow Ubuntu ext4 on userdata
After=local-fs.target
ConditionPathExists=|/usr/sbin/resize2fs
ConditionPathExists=|/sbin/resize2fs

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dagu-resize-root.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

ln -sf /etc/systemd/system/dagu-resize-root.service \
	"$ROOTFS/etc/systemd/system/multi-user.target.wants/dagu-resize-root.service"
if [[ "${DESKTOP:-0}" != 1 ]]; then
	# RNDIS steals the UDC from built-in g_serial. Skip on desktop so
	# ttyGS0 keeps working until Wi-Fi is up.
	ln -sf /etc/systemd/system/dagu-usb-rndis.service \
		"$ROOTFS/etc/systemd/system/multi-user.target.wants/dagu-usb-rndis.service"
fi
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
