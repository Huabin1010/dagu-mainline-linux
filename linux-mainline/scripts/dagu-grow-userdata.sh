#!/bin/sh
# Grow Ubuntu ext4 on userdata to the full partition.
# The 128G UFS userdata is ~106G; the image was left at 8G because
# dagu-resize-root looked for /sbin/resize2fs and the journal is bad
# (init mounts noload). Online resize2fs is refused while EXT4_ERROR_FS.
#
# This pivots to a tmpfs, unmounts /, e2fsck, resize2fs, then reboots.
# Run on the tablet as root. The GNOME session will die; SSH drops.
set -eu

if [ "$(id -u)" -ne 0 ]; then
	echo "run as root" >&2
	exit 1
fi
if [ ! -b /dev/sda34 ]; then
	echo "no /dev/sda34" >&2
	exit 1
fi

dev=/dev/sda34
rescue=/run/dagu-grow
log=/dev/kmsg

klog() { echo "dagu-grow: $*" | tee "$log"; }

copy_bin() {
	bin=$(command -v "$1") || return 1
	cp -a "$bin" "$rescue/bin/"
	# ldd lines: "lib => /path" or "/lib/ld-linux..."
	ldd "$bin" 2>/dev/null | awk '/=>/ {print $3} /^\t\// {print $1}' |
		while read -r so; do
			[ -n "$so" ] && [ -f "$so" ] || continue
			base=$(basename "$so")
			[ -e "$rescue/lib/$base" ] && continue
			cp -a "$so" "$rescue/lib/"
		done
}

klog "stop session"
pkill -u dagu -f 'chrome|chromium|gnome-shell' 2>/dev/null || true
systemctl stop gdm.service 2>/dev/null || true
sleep 1
sync

umount "$rescue" 2>/dev/null || true
rm -rf "$rescue"
mkdir -p "$rescue"
mount -t tmpfs -o size=64M grow "$rescue"
mkdir -p "$rescue"/{bin,lib,proc,sys,dev,oldroot}

copy_bin e2fsck
copy_bin resize2fs
copy_bin busybox || true
if [ -x /usr/local/sbin/dagu-pivot-root ]; then
	cp -a /usr/local/sbin/dagu-pivot-root "$rescue/bin/dagu-pivot-root"
fi
copy_bin mount
copy_bin umount
copy_bin sync
copy_bin sleep
copy_bin sh
# dynamic linker
if [ -x /lib/ld-linux-aarch64.so.1 ]; then
	cp -a /lib/ld-linux-aarch64.so.1 "$rescue/lib/"
	mkdir -p "$rescue/lib64"
	ln -sf ../lib/ld-linux-aarch64.so.1 "$rescue/lib64/ld-linux-aarch64.so.1"
fi
mkdir -p "$rescue/usr/lib/aarch64-linux-gnu" "$rescue/lib/aarch64-linux-gnu"
# keep soname paths ldd expects
for so in "$rescue"/lib/*; do
	[ -e "$so" ] || continue
	ln -sf "/lib/$(basename "$so")" "$rescue/usr/lib/aarch64-linux-gnu/$(basename "$so")" 2>/dev/null || true
	ln -sf "/lib/$(basename "$so")" "$rescue/lib/aarch64-linux-gnu/$(basename "$so")" 2>/dev/null || true
done
ln -sf /lib/ld-linux-aarch64.so.1 "$rescue/lib/ld-linux-aarch64.so.1"
mkdir -p "$rescue/usr/sbin"
ln -sf /bin/e2fsck "$rescue/usr/sbin/e2fsck"
ln -sf /bin/resize2fs "$rescue/usr/sbin/resize2fs"

cat >"$rescue/grow.sh" <<'EOF'
#!/bin/sh
echo "dagu-grow: inside rescue" >/dev/kmsg
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev 2>/dev/null || mount -t tmpfs dev /dev
# Drop the old root so e2fsck can lock the block device.
umount -l /oldroot 2>/dev/null || true
sync
echo "dagu-grow: e2fsck" >/dev/kmsg
/bin/e2fsck -fy /dev/sda34
rc=$?
echo "dagu-grow: e2fsck rc=$rc" >/dev/kmsg
# 0 ok, 1 corrected, 2 corrected+reboot
if [ "$rc" -gt 2 ]; then
	echo "dagu-grow: e2fsck failed, reboot without resize" >/dev/kmsg
	sync
	echo 1 >/proc/sys/kernel/sysrq
	echo b >/proc/sysrq-trigger
	sleep 30
fi
echo "dagu-grow: resize2fs" >/dev/kmsg
/bin/resize2fs /dev/sda34
echo "dagu-grow: resize rc=$?" >/dev/kmsg
sync
echo "dagu-grow: reboot" >/dev/kmsg
echo 1 >/proc/sys/kernel/sysrq
echo b >/proc/sysrq-trigger
sleep 30
EOF
chmod 755 "$rescue/grow.sh"

if [ ! -x "$rescue/bin/dagu-pivot-root" ]; then
	klog "missing dagu-pivot-root"
	exit 1
fi
klog "pivot and grow; SSH will drop; tablet reboots"
cd "$rescue"
exec setsid "$rescue/bin/dagu-pivot-root"
