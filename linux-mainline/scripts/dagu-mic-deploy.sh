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
		/etc/udev/rules.d \
		/etc/systemd/user \
		/usr/local/sbin /usr/local/bin /usr/share/applications'
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
		"$ROOT/alsa/99-dagu-speaker.rules" \
		"root@$HOST:/etc/udev/rules.d/99-dagu-speaker.rules"
	"${SCP[@]}" \
		"$ROOT/systemd/dagu-audio-up.service" \
		"root@$HOST:/etc/systemd/user/dagu-audio-up.service"
	"${SCP[@]}" \
		"$ROOT/scripts/dagu-mic-route.sh" \
		"$ROOT/scripts/dagu-speaker-route.sh" \
		"$ROOT/scripts/dagu-audio-up.sh" \
		"$ROOT/scripts/dagu-va-route.sh" \
		"$ROOT/scripts/dagu-bt-a2dp-route.sh" \
		"$ROOT/scripts/dagu-adsp-voice-test.sh" \
		"root@$HOST:/usr/local/sbin/"
	"${SCP[@]}" \
		"$ROOT/alsa/50-dagu-bt-offload.conf" \
		"root@$HOST:/etc/wireplumber/wireplumber.conf.d/50-dagu-bt-offload.conf"
	"${SCP[@]}" \
		"$ROOT/scripts/dagu-mic-test.py" \
		"root@$HOST:/usr/local/bin/dagu-mic-test"
	"${SCP[@]}" \
		"$ROOT/scripts/dagu_mic_lib.py" \
		"root@$HOST:/usr/local/bin/dagu_mic_lib.py"
	"${SCP[@]}" \
		"$ROOT/alsa/org.dagu.MicTest.desktop" \
		"root@$HOST:/usr/share/applications/org.dagu.MicTest.desktop"
	"${SSH[@]}" 'set -e
		chmod 755 /usr/local/sbin/dagu-mic-route.sh \
			/usr/local/sbin/dagu-speaker-route.sh \
			/usr/local/sbin/dagu-audio-up.sh \
			/usr/local/sbin/dagu-va-route.sh \
			/usr/local/sbin/dagu-bt-a2dp-route.sh \
			/usr/local/sbin/dagu-adsp-voice-test.sh \
			/usr/local/bin/dagu-mic-test
		update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
		udevadm control --reload-rules 2>/dev/null || true
		alsaucm -c hw:0 reload 2>/dev/null || true
		/usr/local/sbin/dagu-mic-route.sh || true
		if [ -d /run/user/1001 ]; then
			sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 \
				DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
				systemctl --user daemon-reload || true
			sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 \
				DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
				systemctl --user try-restart \
					pipewire.service pipewire-pulse.service \
					wireplumber.service || true
			sleep 4
			sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 \
				DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
				/usr/local/sbin/dagu-audio-up.sh || true
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
	"${CONSOLE[@]}" put "$ROOT/scripts/dagu-va-route.sh" \
		/usr/local/sbin/dagu-va-route.sh
	"${CONSOLE[@]}" put "$ROOT/scripts/dagu-bt-a2dp-route.sh" \
		/usr/local/sbin/dagu-bt-a2dp-route.sh
	"${CONSOLE[@]}" put "$ROOT/scripts/dagu-adsp-voice-test.sh" \
		/usr/local/sbin/dagu-adsp-voice-test.sh
	"${CONSOLE[@]}" put "$ROOT/alsa/50-dagu-bt-offload.conf" \
		/etc/wireplumber/wireplumber.conf.d/50-dagu-bt-offload.conf
	"${CONSOLE[@]}" run 'chmod 755 /usr/local/sbin/dagu-mic-route.sh /usr/local/sbin/dagu-speaker-route.sh /usr/local/sbin/dagu-audio-up.sh /usr/local/sbin/dagu-va-route.sh /usr/local/sbin/dagu-bt-a2dp-route.sh /usr/local/sbin/dagu-adsp-voice-test.sh; mkdir -p /usr/share/alsa/ucm2/Xiaomi-dagu /usr/share/alsa/ucm2/conf.d/sm8250 /usr/share/alsa/ucm2/conf.d/snd-sm8250 /etc/wireplumber/wireplumber.conf.d; alsaucm -c hw:0 reload; /usr/local/sbin/dagu-mic-route.sh; if [ -d /run/user/1001 ]; then sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus systemctl --user try-restart pipewire.service pipewire-pulse.service wireplumber.service; sleep 4; sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus /usr/local/sbin/dagu-audio-up.sh; fi; echo DAGU_MIC_DEPLOY_OK'
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
