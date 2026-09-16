#!/usr/bin/env bash
# Push Snapshot-touch fixes to a live dagu (no kernel flash).
# Product path is the Rust+C++ loopback and C daemons. No Python/GStreamer.
# Prefers Wi-Fi SSH; falls back to g_serial /dev/ttyACM0.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${DAGU_HOST:-192.168.7.2}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"
SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "root@$HOST")
SCP=(scp -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null)
CONSOLE=(python3 "$ROOT/scripts/dagu-console.py")
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"

have_ssh() {
	timeout 12 "${SSH[@]}" true >/dev/null 2>&1
}

is_elf() {
	[[ -x "$1" ]] && [[ "$(head -c 4 "$1")" == $'\x7fELF' ]]
}

make -C "$ROOT/userspace" CC="${CROSS}gcc"

if ! is_elf "$ROOT/camera-loopback/dagu-camera-loopback"; then
	echo "build camera-loopback (aarch64 ELF) first — refusing Python/GStreamer .sh" >&2
	exit 1
fi
is_elf "$ROOT/userspace/dagu-touch-boost" || {
	echo "missing userspace/dagu-touch-boost" >&2
	exit 1
}
is_elf "$ROOT/userspace/dagu-power-button" || {
	echo "missing userspace/dagu-power-button" >&2
	exit 1
}

copy_ssh() {
	"${SSH[@]}" 'mkdir -p /usr/local/sbin /etc/systemd/system /etc/libcamera /usr/local/share/dagu /etc/systemd/user/pipewire.service.d /etc/systemd/user/wireplumber.service.d /etc/wireplumber/wireplumber.conf.d /etc/udev/rules.d /etc/modprobe.d /etc/modules-load.d'
	"${SCP[@]}" "$ROOT/camera-loopback/dagu-camera-loopback" \
		"$ROOT/userspace/dagu-touch-boost" \
		"$ROOT/userspace/dagu-power-button" \
		"root@$HOST:/usr/local/sbin/"
	"${SCP[@]}" \
		"$ROOT/scripts/dagu-himax-irq-affinity.sh" \
		"$ROOT/scripts/dagu-libcamera-softisp.sh" \
		"$ROOT/scripts/dagu-camss-graph-reset.sh" \
		"root@$HOST:/usr/local/sbin/"
	"${SCP[@]}" \
		"$ROOT/systemd/dagu-camera-loopback.service" \
		"$ROOT/systemd/dagu-camera-loopback-watch.service" \
		"$ROOT/systemd/dagu-himax-irq-affinity.service" \
		"$ROOT/systemd/dagu-touch-boost.service" \
		"$ROOT/systemd/dagu-power-button.service" \
		"root@$HOST:/etc/systemd/system/"
	"${SCP[@]}" "$ROOT/systemd/dagu-camss-reset.conf" \
		"root@$HOST:/etc/systemd/user/pipewire.service.d/dagu-camss-reset.conf"
	"${SCP[@]}" "$ROOT/systemd/dagu-camss-reset.conf" \
		"root@$HOST:/etc/systemd/user/wireplumber.service.d/dagu-camss-reset.conf"
	"${SCP[@]}" "$ROOT/systemd/60-dagu-camera.conf" \
		"root@$HOST:/etc/wireplumber/wireplumber.conf.d/60-dagu-camera.conf"
	"${SCP[@]}" "$ROOT/systemd/90-dagu-v4l2loopback.rules" \
		"root@$HOST:/etc/udev/rules.d/90-dagu-v4l2loopback.rules"
	"${SCP[@]}" "$ROOT/systemd/v4l2loopback.conf" \
		"root@$HOST:/etc/modprobe.d/v4l2loopback.conf"
	"${SCP[@]}" "$ROOT/libcamera/dagu-viewfinder-bin.patch" \
		"root@$HOST:/usr/local/share/dagu/dagu-viewfinder-bin.patch" || true
	"${SSH[@]}" 'set -e
		chmod 755 /usr/local/sbin/dagu-camera-loopback \
			/usr/local/sbin/dagu-touch-boost \
			/usr/local/sbin/dagu-power-button \
			/usr/local/sbin/dagu-himax-irq-affinity.sh \
			/usr/local/sbin/dagu-libcamera-softisp.sh \
			/usr/local/sbin/dagu-camss-graph-reset.sh
		rm -f /usr/local/sbin/dagu-camera-loopback.sh \
			/usr/local/sbin/dagu-touch-boost.py \
			/usr/local/sbin/dagu-power-button.py \
			/usr/local/sbin/dagu-tablet-mode.py \
			/usr/local/sbin/dagu-time-sync.py \
			/usr/local/bin/dagu-fcitx5-shift-tap.py \
			/usr/local/sbin/dagu-camera-pw-source.py \
			/usr/local/sbin/dagu-camera-preview.py
		systemctl disable --now dagu-tablet-mode.service dagu-time-sync.service \
			dagu-time-sync.timer dagu-fcitx5-shift-tap.service \
			dagu-camera-loopback.service 2>/dev/null || true
		rm -f /etc/systemd/system/multi-user.target.wants/dagu-camera-loopback.service \
			/etc/systemd/system/multi-user.target.wants/dagu-tablet-mode.service \
			/etc/systemd/system/multi-user.target.wants/dagu-time-sync.service \
			/etc/systemd/system/timers.target.wants/dagu-time-sync.timer
		ln -sfn libcamera.so.0.7.0 /usr/lib/aarch64-linux-gnu/libcamera.so.0.7
		ln -sfn libcamera-base.so.0.7.0 /usr/lib/aarch64-linux-gnu/libcamera-base.so.0.7
		mkdir -p /var/backups/dagu-libcamera
		for stub in libcamera.so.0.7.0.dagu libcamera-base.so.0.7.0.dagu; do
			if [ -e /usr/lib/aarch64-linux-gnu/$stub ]; then
				mv -f /usr/lib/aarch64-linux-gnu/$stub /var/backups/dagu-libcamera/$stub
			fi
		done
		ldconfig
		if [ -f /usr/local/sbin/dagu-speaker-route.sh ]; then
			sed -i "s/try-restart wireplumber/try-restart pipewire.service/" \
				/usr/local/sbin/dagu-speaker-route.sh
		fi
		pkill -TERM snapshot 2>/dev/null || true
		/usr/local/sbin/dagu-camss-graph-reset.sh || true
		if [ -d /run/user/1001 ]; then
			sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 \
				DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
				systemctl --user daemon-reload || true
			sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 \
				DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
				systemctl --user restart pipewire.service || true
		fi
		mkdir -p /etc/libcamera /usr/local/share/dagu /etc/wireplumber/wireplumber.conf.d /etc/modules-load.d
		echo v4l2loopback >/etc/modules-load.d/dagu-v4l2loopback.conf
		udevadm control --reload || true
		udevadm trigger --subsystem-match=video4linux || true
		systemctl daemon-reload
		systemctl enable --now dagu-camera-loopback-watch.service
		systemctl enable --now dagu-himax-irq-affinity.service
		systemctl enable --now dagu-touch-boost.service
		systemctl enable --now dagu-power-button.service
		systemctl enable --now systemd-timesyncd.service || true
		/usr/local/sbin/dagu-himax-irq-affinity.sh || true
		echo DAGU_TOUCH_DEPLOY_OK
		readlink /proc/$(pidof dagu-camera-loopback)/exe || true
		systemctl is-active dagu-touch-boost.service dagu-camera-loopback-watch.service dagu-himax-irq-affinity.service dagu-camera-loopback.service || true
		grep -i himax /proc/interrupts | head -1
	'
}

copy_serial() {
	"${CONSOLE[@]}" put "$ROOT/camera-loopback/dagu-camera-loopback" /usr/local/sbin/dagu-camera-loopback
	"${CONSOLE[@]}" put "$ROOT/userspace/dagu-touch-boost" /usr/local/sbin/dagu-touch-boost
	"${CONSOLE[@]}" put "$ROOT/userspace/dagu-power-button" /usr/local/sbin/dagu-power-button
	"${CONSOLE[@]}" put "$ROOT/scripts/dagu-himax-irq-affinity.sh" /usr/local/sbin/dagu-himax-irq-affinity.sh
	"${CONSOLE[@]}" put "$ROOT/scripts/dagu-camss-graph-reset.sh" /usr/local/sbin/dagu-camss-graph-reset.sh
	"${CONSOLE[@]}" put "$ROOT/systemd/dagu-camss-reset.conf" /etc/systemd/user/pipewire.service.d/dagu-camss-reset.conf
	"${CONSOLE[@]}" put "$ROOT/systemd/dagu-camss-reset.conf" /etc/systemd/user/wireplumber.service.d/dagu-camss-reset.conf
	"${CONSOLE[@]}" put "$ROOT/systemd/dagu-camera-loopback.service" /etc/systemd/system/dagu-camera-loopback.service
	"${CONSOLE[@]}" put "$ROOT/systemd/dagu-camera-loopback-watch.service" /etc/systemd/system/dagu-camera-loopback-watch.service
	"${CONSOLE[@]}" put "$ROOT/systemd/dagu-himax-irq-affinity.service" /etc/systemd/system/dagu-himax-irq-affinity.service
	"${CONSOLE[@]}" put "$ROOT/systemd/dagu-touch-boost.service" /etc/systemd/system/dagu-touch-boost.service
	"${CONSOLE[@]}" put "$ROOT/systemd/dagu-power-button.service" /etc/systemd/system/dagu-power-button.service
	"${CONSOLE[@]}" put "$ROOT/systemd/60-dagu-camera.conf" /etc/wireplumber/wireplumber.conf.d/60-dagu-camera.conf
	"${CONSOLE[@]}" put "$ROOT/systemd/90-dagu-v4l2loopback.rules" /etc/udev/rules.d/90-dagu-v4l2loopback.rules
	"${CONSOLE[@]}" put "$ROOT/systemd/v4l2loopback.conf" /etc/modprobe.d/v4l2loopback.conf
	"${CONSOLE[@]}" run 'chmod 755 /usr/local/sbin/dagu-camera-loopback /usr/local/sbin/dagu-touch-boost /usr/local/sbin/dagu-power-button /usr/local/sbin/dagu-himax-irq-affinity.sh /usr/local/sbin/dagu-camss-graph-reset.sh; rm -f /usr/local/sbin/dagu-camera-loopback.sh /usr/local/sbin/dagu-touch-boost.py /usr/local/sbin/dagu-power-button.py; mkdir -p /etc/systemd/user/pipewire.service.d /etc/systemd/user/wireplumber.service.d; ln -sfn libcamera.so.0.7.0 /usr/lib/aarch64-linux-gnu/libcamera.so.0.7; ln -sfn libcamera-base.so.0.7.0 /usr/lib/aarch64-linux-gnu/libcamera-base.so.0.7; ldconfig; /usr/local/sbin/dagu-camss-graph-reset.sh; systemctl stop dagu-camera-loopback.service; systemctl disable dagu-camera-loopback.service; rm -f /etc/systemd/system/multi-user.target.wants/dagu-camera-loopback.service; systemctl daemon-reload; systemctl enable --now dagu-camera-loopback-watch.service; systemctl enable --now dagu-himax-irq-affinity.service; systemctl enable --now dagu-touch-boost.service; /usr/local/sbin/dagu-himax-irq-affinity.sh; echo DAGU_TOUCH_DEPLOY_OK'
}

if have_ssh; then
	echo "==> Wi-Fi SSH $HOST"
	copy_ssh
elif [[ -e /dev/ttyACM0 ]]; then
	echo "==> g_serial /dev/ttyACM0"
	copy_serial
else
	echo "no SSH to $HOST and no /dev/ttyACM0" >&2
	exit 1
fi
