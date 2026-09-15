#!/usr/bin/env bash
# Push Snapshot-touch fixes to a live dagu (no kernel flash).
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

have_ssh() {
	timeout 12 "${SSH[@]}" true >/dev/null 2>&1
}

copy_ssh() {
	"${SSH[@]}" 'mkdir -p /usr/local/sbin /etc/systemd/system /etc/libcamera /usr/local/share/dagu /etc/systemd/user/pipewire.service.d /etc/systemd/user/wireplumber.service.d /etc/wireplumber/wireplumber.conf.d /etc/udev/rules.d /etc/modprobe.d /etc/modules-load.d'
	if [[ -x "$ROOT/camera-loopback/dagu-camera-loopback" ]]; then
		"${SCP[@]}" "$ROOT/camera-loopback/dagu-camera-loopback" \
			"root@$HOST:/usr/local/sbin/dagu-camera-loopback"
	fi
	"${SCP[@]}" \
		"$ROOT/scripts/dagu-camera-loopback.sh" \
		"$ROOT/scripts/dagu-touch-boost.py" \
		"$ROOT/scripts/dagu-himax-irq-affinity.sh" \
		"$ROOT/scripts/dagu-libcamera-softisp.sh" \
		"$ROOT/scripts/dagu-camss-graph-reset.sh" \
		"root@$HOST:/usr/local/sbin/"
	"${SCP[@]}" \
		"$ROOT/systemd/dagu-camera-loopback.service" \
		"$ROOT/systemd/dagu-camera-loopback-watch.service" \
		"$ROOT/systemd/dagu-himax-irq-affinity.service" \
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
		chmod 755 /usr/local/sbin/dagu-camera-loopback.sh \
			/usr/local/sbin/dagu-touch-boost.py \
			/usr/local/sbin/dagu-himax-irq-affinity.sh \
			/usr/local/sbin/dagu-libcamera-softisp.sh \
			/usr/local/sbin/dagu-camss-graph-reset.sh
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
		systemctl stop dagu-camera-loopback.service 2>/dev/null || true
		systemctl disable dagu-camera-loopback.service 2>/dev/null || true
		rm -f /etc/systemd/system/multi-user.target.wants/dagu-camera-loopback.service
		systemctl daemon-reload
		systemctl enable --now dagu-camera-loopback-watch.service
		systemctl enable --now dagu-himax-irq-affinity.service
		systemctl restart dagu-touch-boost.service
		/usr/local/sbin/dagu-himax-irq-affinity.sh || true
		echo DAGU_TOUCH_DEPLOY_OK
		systemctl is-active dagu-touch-boost.service dagu-camera-loopback-watch.service dagu-himax-irq-affinity.service dagu-camera-loopback.service || true
		grep -i himax /proc/interrupts | head -1
		cat /proc/irq/*/smp_affinity_list 2>/dev/null | head
	'
}

copy_serial() {
	mkdir -p /tmp
	"${CONSOLE[@]}" put "$ROOT/scripts/dagu-camera-loopback.sh" /usr/local/sbin/dagu-camera-loopback.sh
	"${CONSOLE[@]}" put "$ROOT/scripts/dagu-touch-boost.py" /usr/local/sbin/dagu-touch-boost.py
	"${CONSOLE[@]}" put "$ROOT/scripts/dagu-himax-irq-affinity.sh" /usr/local/sbin/dagu-himax-irq-affinity.sh
	"${CONSOLE[@]}" put "$ROOT/scripts/dagu-camss-graph-reset.sh" /usr/local/sbin/dagu-camss-graph-reset.sh
	"${CONSOLE[@]}" put "$ROOT/systemd/dagu-camss-reset.conf" /etc/systemd/user/pipewire.service.d/dagu-camss-reset.conf
	"${CONSOLE[@]}" put "$ROOT/systemd/dagu-camss-reset.conf" /etc/systemd/user/wireplumber.service.d/dagu-camss-reset.conf
	"${CONSOLE[@]}" put "$ROOT/systemd/dagu-camera-loopback.service" /etc/systemd/system/dagu-camera-loopback.service
	"${CONSOLE[@]}" put "$ROOT/systemd/dagu-camera-loopback-watch.service" /etc/systemd/system/dagu-camera-loopback-watch.service
	"${CONSOLE[@]}" put "$ROOT/systemd/dagu-himax-irq-affinity.service" /etc/systemd/system/dagu-himax-irq-affinity.service
	"${CONSOLE[@]}" put "$ROOT/systemd/60-dagu-camera.conf" /etc/wireplumber/wireplumber.conf.d/60-dagu-camera.conf
	"${CONSOLE[@]}" put "$ROOT/systemd/90-dagu-v4l2loopback.rules" /etc/udev/rules.d/90-dagu-v4l2loopback.rules
	"${CONSOLE[@]}" put "$ROOT/systemd/v4l2loopback.conf" /etc/modprobe.d/v4l2loopback.conf
	"${CONSOLE[@]}" run 'chmod 755 /usr/local/sbin/dagu-camera-loopback.sh /usr/local/sbin/dagu-touch-boost.py /usr/local/sbin/dagu-himax-irq-affinity.sh /usr/local/sbin/dagu-camss-graph-reset.sh; mkdir -p /etc/systemd/user/pipewire.service.d /etc/systemd/user/wireplumber.service.d; ln -sfn libcamera.so.0.7.0 /usr/lib/aarch64-linux-gnu/libcamera.so.0.7; ln -sfn libcamera-base.so.0.7.0 /usr/lib/aarch64-linux-gnu/libcamera-base.so.0.7; ldconfig; /usr/local/sbin/dagu-camss-graph-reset.sh; systemctl stop dagu-camera-loopback.service; systemctl disable dagu-camera-loopback.service; rm -f /etc/systemd/system/multi-user.target.wants/dagu-camera-loopback.service; systemctl daemon-reload; systemctl enable --now dagu-camera-loopback-watch.service; systemctl enable --now dagu-himax-irq-affinity.service; systemctl restart dagu-touch-boost.service; /usr/local/sbin/dagu-himax-irq-affinity.sh; echo DAGU_TOUCH_DEPLOY_OK'
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
