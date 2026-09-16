#!/usr/bin/env bash
# Push built-in mic UCM + mixer route to a live dagu (no kernel flash).
# Prefers Wi-Fi SSH; falls back to g_serial /dev/ttyACM0.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${DAGU_HOST:-${DAGU_SSH_HOST:-192.168.7.2}}"
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
	"${SSH[@]}" 'mkdir -p /usr/share/alsa/ucm2/Xiaomi-dagu \
		/usr/share/alsa/ucm2/conf.d/sm8250 \
		/usr/share/alsa/ucm2/conf.d/snd-sm8250 \
		/etc/wireplumber/wireplumber.conf.d \
		/usr/local/sbin'
	"${SCP[@]}" \
		"$ROOT/alsa/ucm2/Xiaomi-dagu/HiFi.conf" \
		"root@$HOST:/usr/share/alsa/ucm2/Xiaomi-dagu/HiFi.conf"
	"${SCP[@]}" \
		"$ROOT/alsa/ucm2/conf.d/sm8250/Xiaomi-dagu-CS35L41-WCD9385.conf" \
		"root@$HOST:/usr/share/alsa/ucm2/conf.d/sm8250/Xiaomi-dagu-CS35L41-WCD9385.conf"
	"${SCP[@]}" \
		"$ROOT/alsa/ucm2/conf.d/sm8250/Xiaomi-dagu-CS35L41-WCD9385.conf" \
		"root@$HOST:/usr/share/alsa/ucm2/conf.d/snd-sm8250/Xiaomi-dagu-CS35L41-WCD9385.conf"
	"${SCP[@]}" \
		"$ROOT/alsa/50-dagu-speaker.conf" \
		"root@$HOST:/etc/wireplumber/wireplumber.conf.d/50-dagu-speaker.conf"
	"${SCP[@]}" \
		"$ROOT/scripts/dagu-mic-route.sh" \
		"$ROOT/scripts/dagu-speaker-route.sh" \
		"$ROOT/scripts/dagu-audio-up.sh" \
		"root@$HOST:/usr/local/sbin/"
	"${SSH[@]}" 'set -e
		chmod 755 /usr/local/sbin/dagu-mic-route.sh \
			/usr/local/sbin/dagu-speaker-route.sh \
			/usr/local/sbin/dagu-audio-up.sh
		alsaucm -c hw:0 reload 2>/dev/null || true
		/usr/local/sbin/dagu-mic-route.sh || true
		if [ -d /run/user/1001 ]; then
			sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 \
				DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
				systemctl --user try-restart wireplumber.service || true
		fi
		echo DAGU_MIC_DEPLOY_OK
	'
}

copy_serial() {
	"${CONSOLE[@]}" put "$ROOT/alsa/ucm2/Xiaomi-dagu/HiFi.conf" \
		/usr/share/alsa/ucm2/Xiaomi-dagu/HiFi.conf
	"${CONSOLE[@]}" put "$ROOT/alsa/ucm2/conf.d/sm8250/Xiaomi-dagu-CS35L41-WCD9385.conf" \
		/usr/share/alsa/ucm2/conf.d/sm8250/Xiaomi-dagu-CS35L41-WCD9385.conf
	"${CONSOLE[@]}" put "$ROOT/alsa/ucm2/conf.d/sm8250/Xiaomi-dagu-CS35L41-WCD9385.conf" \
		/usr/share/alsa/ucm2/conf.d/snd-sm8250/Xiaomi-dagu-CS35L41-WCD9385.conf
	"${CONSOLE[@]}" put "$ROOT/alsa/50-dagu-speaker.conf" \
		/etc/wireplumber/wireplumber.conf.d/50-dagu-speaker.conf
	"${CONSOLE[@]}" put "$ROOT/scripts/dagu-mic-route.sh" \
		/usr/local/sbin/dagu-mic-route.sh
	"${CONSOLE[@]}" put "$ROOT/scripts/dagu-speaker-route.sh" \
		/usr/local/sbin/dagu-speaker-route.sh
	"${CONSOLE[@]}" put "$ROOT/scripts/dagu-audio-up.sh" \
		/usr/local/sbin/dagu-audio-up.sh
	"${CONSOLE[@]}" run 'chmod 755 /usr/local/sbin/dagu-mic-route.sh /usr/local/sbin/dagu-speaker-route.sh /usr/local/sbin/dagu-audio-up.sh; mkdir -p /usr/share/alsa/ucm2/Xiaomi-dagu /usr/share/alsa/ucm2/conf.d/sm8250 /usr/share/alsa/ucm2/conf.d/snd-sm8250 /etc/wireplumber/wireplumber.conf.d; alsaucm -c hw:0 reload; /usr/local/sbin/dagu-mic-route.sh; if [ -d /run/user/1001 ]; then sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus systemctl --user try-restart wireplumber.service; fi; echo DAGU_MIC_DEPLOY_OK'
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
