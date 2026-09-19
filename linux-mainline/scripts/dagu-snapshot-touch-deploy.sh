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
	"${SSH[@]}" 'mkdir -p /usr/local/sbin /etc/systemd/system /etc/libcamera /usr/local/share/dagu /etc/systemd/user/pipewire.service.d /etc/systemd/user/wireplumber.service.d /etc/wireplumber/wireplumber.conf.d /etc/udev/rules.d /etc/modprobe.d /etc/modules-load.d /usr/lib/systemd/system-sleep /etc/NetworkManager/conf.d'
	"${SCP[@]}" "$ROOT/camera-loopback/dagu-camera-loopback" \
		"$ROOT/userspace/dagu-touch-boost" \
		"$ROOT/userspace/dagu-power-button" \
		"root@$HOST:/usr/local/sbin/"
	"${SCP[@]}" "$ROOT/scripts/dagu-linear-mod.c" \
		"root@$HOST:/tmp/dagu-linear-mod.c"
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
		"root@$HOST:/etc/systemd/system/"
	"${SSH[@]}" 'mkdir -p /etc/systemd/logind.conf.d /etc/dconf/db/local.d/locks'
	"${SCP[@]}" "$ROOT/systemd/logind-dagu-power.conf" \
		"root@$HOST:/etc/systemd/logind.conf.d/dagu-power.conf"
	"${SCP[@]}" "$ROOT/dconf/00-dagu-power" \
		"root@$HOST:/etc/dconf/db/local.d/00-dagu-power"
	"${SCP[@]}" "$ROOT/dconf/locks-dagu-power" \
		"root@$HOST:/etc/dconf/db/local.d/locks/dagu-power"
	"${SCP[@]}" "$ROOT/systemd/dagu-camss-reset.conf" \
		"root@$HOST:/etc/systemd/user/pipewire.service.d/dagu-camss-reset.conf"
	"${SCP[@]}" "$ROOT/systemd/dagu-camss-reset.conf" \
		"root@$HOST:/etc/systemd/user/wireplumber.service.d/dagu-camss-reset.conf"
	"${SCP[@]}" "$ROOT/systemd/60-dagu-camera.conf" \
		"root@$HOST:/etc/wireplumber/wireplumber.conf.d/60-dagu-camera.conf"
	"${SCP[@]}" "$ROOT/systemd/90-dagu-v4l2loopback.rules" \
		"root@$HOST:/etc/udev/rules.d/90-dagu-v4l2loopback.rules"
	"${SCP[@]}" "$ROOT/systemd/70-dagu-wifi-wakeup.rules" \
		"root@$HOST:/etc/udev/rules.d/70-dagu-wifi-wakeup.rules"
	"${SCP[@]}" "$ROOT/systemd/20-dagu-wifi-wowlan.conf" \
		"root@$HOST:/etc/NetworkManager/conf.d/20-dagu-wifi-wowlan.conf"
	"${SCP[@]}" "$ROOT/scripts/dagu-wifi-wowlan-apply.sh" \
		"root@$HOST:/usr/local/sbin/dagu-wifi-wowlan-apply"
	"${SCP[@]}" "$ROOT/systemd/dagu-folio-resume" \
		"root@$HOST:/usr/lib/systemd/system-sleep/dagu-folio-resume"
	"${SCP[@]}" "$ROOT/systemd/v4l2loopback.conf" \
		"root@$HOST:/etc/modprobe.d/v4l2loopback.conf"
	if [ -f "$ROOT/out/v4l2loopback.ko" ]; then
		"${SCP[@]}" "$ROOT/out/v4l2loopback.ko" \
			"root@$HOST:/tmp/v4l2loopback.ko"
	fi
	"${SCP[@]}" "$ROOT/libcamera/dagu-viewfinder-bin.patch" \
		"root@$HOST:/usr/local/share/dagu/dagu-viewfinder-bin.patch" || true
	"${SSH[@]}" 'set -e
		if [ -f /tmp/dagu-linear-mod.c ]; then
			gcc -O2 -fPIC -shared -o /usr/local/lib/libdagu-linear-mod.so \
				/tmp/dagu-linear-mod.c -ldl
		fi
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
			dagu-time-sync.timer \
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
		if [ -f /tmp/v4l2loopback.ko ]; then
			mkdir -p /lib/modules/$(uname -r)/updates
			install -m644 /tmp/v4l2loopback.ko \
				/lib/modules/$(uname -r)/updates/v4l2loopback.ko
			depmod -a 2>/dev/null || true
		fi
		udevadm control --reload || true
		udevadm trigger --subsystem-match=video4linux || true
		systemctl daemon-reload
		systemctl enable --now dagu-camera-loopback-watch.service
		systemctl enable --now dagu-himax-irq-affinity.service
		systemctl enable --now dagu-touch-boost.service
		dconf update || true
		systemctl disable --now dagu-power-button.service || true
		rm -f /usr/local/sbin/dagu-power-menu \
			/usr/share/applications/org.dagu.PowerMenu.desktop
		systemctl unmask sleep.target suspend.target || true
		systemctl kill -s HUP systemd-logind.service || true
		chmod 755 /usr/local/sbin/dagu-wifi-wowlan-apply \
			/usr/lib/systemd/system-sleep/dagu-folio-resume || true
		/usr/local/sbin/dagu-wifi-wowlan-apply || true
		udevadm control --reload || true
		udevadm trigger --subsystem-match=pci --subsystem-match=net || true
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
	"${CONSOLE[@]}" put "$ROOT/systemd/logind-dagu-power.conf" /etc/systemd/logind.conf.d/dagu-power.conf
	"${CONSOLE[@]}" put "$ROOT/dconf/00-dagu-power" /etc/dconf/db/local.d/00-dagu-power
	"${CONSOLE[@]}" put "$ROOT/dconf/locks-dagu-power" /etc/dconf/db/local.d/locks/dagu-power
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
